// Mounts every AION2 pak / IoStore container with the archive key, writes the raw virtual files,
// and decrypts the AION2-protected .dat files into .bin payloads plus a decryption manifest.
//
// usage: Aion2Extractor --paks <Content/Paks> (--key-file <file with 0x...64 hex> | --key <0x...>)
//                       --raw <dir> --output <dir> [--data-only] [--threads N]
//   --raw     receives every extracted virtual file (AION2/Content/...), unchanged.
//   --output  receives decrypted/** (.bin payloads, JSON where the format is JSON) and
//             decryption-manifest.csv, the layout the decoder and the database import read.
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using CUE4Parse.Compression;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.FileProvider.Objects;
using CUE4Parse.GameTypes.Aion2.Encryption.Aes;
using CUE4Parse.GameTypes.Aion2.Objects;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Versions;
using CUE4Parse.UE4.VirtualFileSystem;
using Newtonsoft.Json;

var options = ParseArguments(args);
var paks = Required(options, "paks");
var rawRoot = Path.GetFullPath(Required(options, "raw"));
var outputRoot = Path.GetFullPath(Required(options, "output"));
var decryptedRoot = Path.Combine(outputRoot, "decrypted");
var dataOnly = options.ContainsKey("data-only");
var threads = options.TryGetValue("threads", out var t) ? int.Parse(t) : Environment.ProcessorCount;
var keyText = options.TryGetValue("key", out var inlineKey) ? inlineKey : File.ReadAllText(Required(options, "key-file"));
var keyMatch = Regex.Match(keyText, "(?:0x)?[0-9A-Fa-f]{64}");
if (!keyMatch.Success) throw new InvalidOperationException("No 256-bit AES key in the key file");
var aesKey = keyMatch.Value.StartsWith("0x") ? keyMatch.Value : "0x" + keyMatch.Value;

// Oodle / zlib-ng decompress UE5 containers; CUE4Parse downloads the DLLs once if they are missing.
var nativeCache = Path.Combine(AppContext.BaseDirectory, ".natives");
Directory.CreateDirectory(nativeCache);
OodleHelper.Initialize(Path.Combine(nativeCache, OodleHelper.OodleFileName));
ZlibHelper.Initialize(Path.Combine(nativeCache, ZlibHelper.DllName));

var provider = new DefaultFileProvider(paks, SearchOption.AllDirectories,
    new VersionContainer(EGame.GAME_Aion2), StringComparer.OrdinalIgnoreCase);
provider.Initialize();
provider.SubmitKey(new FGuid(), new FAesKey(aesKey));
provider.Mount();
provider.PostMount();
Console.WriteLine($"Mounted {provider.Files.Count:N0} files from {paks}");
if (provider.Files.Count == 0) throw new InvalidOperationException("No files mounted; check the AES key");

// Data needed by the server: game data, startup tables, localization (and every .dat).
static bool IsGameData(string path) =>
    path.EndsWith(".dat", StringComparison.OrdinalIgnoreCase)
    || path.Contains("/Content/Data/", StringComparison.OrdinalIgnoreCase)
    || path.Contains("/Content/StartUpData/", StringComparison.OrdinalIgnoreCase)
    || path.Contains("/Content/L10N/", StringComparison.OrdinalIgnoreCase);

var files = provider.Files.Values.Where(f => !dataOnly || IsGameData(f.Path)).ToList();
Console.WriteLine($"Extracting {files.Count:N0} files to {rawRoot}{(dataOnly ? " (game data only)" : "")}");
var errors = new ConcurrentBag<string>();
long written = 0, skipped = 0, done = 0;
Parallel.ForEach(files, new ParallelOptions { MaxDegreeOfParallelism = threads }, file =>
{
    try
    {
        var target = Path.Combine(rawRoot, file.Path.Replace('/', Path.DirectorySeparatorChar));
        if (File.Exists(target) && new FileInfo(target).Length == file.Size)
        {
            Interlocked.Increment(ref skipped);
        }
        else
        {
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.WriteAllBytes(target, file.Read());
            Interlocked.Increment(ref written);
        }
    }
    catch (Exception e)
    {
        errors.Add($"extract {file.Path}: {e.Message}");
    }
    var current = Interlocked.Increment(ref done);
    if (current % 5000 == 0) Console.WriteLine($"  {current:N0}/{files.Count:N0}");
});
Console.WriteLine($"Extracted {written:N0}, already present {skipped:N0}, failed {errors.Count:N0}");

// AION2 .dat protection (docs/client-data-decryption.md).
Aion2DatFileEncryption.Initialize(provider);
if (Aion2DatFileEncryption.AesKeys.Count == 0) throw new InvalidOperationException("key_manifest.dat did not yield keys");
var datFiles = provider.Files.Values.Where(f => f.Path.EndsWith(".dat", StringComparison.OrdinalIgnoreCase))
    .OrderBy(f => f.Path, StringComparer.Ordinal).ToList();
var rows = new ConcurrentBag<string[]>();
Parallel.ForEach(datFiles, new ParallelOptions { MaxDegreeOfParallelism = threads }, file =>
{
    try
    {
        rows.Add(Decrypt(file));
    }
    catch (Exception e)
    {
        errors.Add($"decrypt {file.Path}: {e.Message}");
    }
});

var manifestPath = Path.Combine(outputRoot, "decryption-manifest.csv");
using (var manifest = new StreamWriter(manifestPath, false, new UTF8Encoding(false)) { NewLine = "\r\n" })
{
    manifest.WriteLine(Csv(["virtual_path", "family", "algorithm", "source_container", "decrypted_path",
        "decrypted_bytes", "decrypted_sha256", "structured_status", "structured_json_path"]));
    foreach (var row in rows.OrderBy(r => r[0], StringComparer.Ordinal)) manifest.WriteLine(Csv(row));
}
Console.WriteLine($"Decrypted {rows.Count:N0}/{datFiles.Count:N0} .dat files -> {decryptedRoot}");
Console.WriteLine($"Manifest: {manifestPath}");

var errorPath = Path.Combine(outputRoot, "extract-errors.txt");
File.WriteAllLines(errorPath, errors.Order());
if (!errors.IsEmpty)
{
    Console.WriteLine($"{errors.Count:N0} errors, see {errorPath}");
    return 2;
}
return 0;

string[] Decrypt(GameFile file)
{
    var path = file.Path;
    var lower = "/" + path.ToLowerInvariant();
    var data = file.Read();
    string family, algorithm;
    string? json = null;
    byte[] output;
    if (lower.EndsWith("/key_manifest.dat"))
    {
        (family, algorithm) = ("startup-table", "manifest-blake3-derived-aes-256-ecb");
        output = data;  // the keys themselves are written as JSON
        json = JsonConvert.SerializeObject(new FAion2KeyManifestFile(file), Formatting.Indented);
    }
    else if (lower.Contains("/l10n/"))
    {
        (family, algorithm) = ("localization", "manifest-keyed-aes-256-ecb-lz4");
        output = Aion2DatFileEncryption.DecryptL10N(data, path);
        json = JsonConvert.SerializeObject(new FAion2L10NFile(file, provider), Formatting.Indented);
    }
    else if (lower.Contains("/data/table/") || lower.Contains("/startupdata/table/"))
    {
        family = lower.Contains("/startupdata/") ? "startup-table" : "gameplay-table";
        algorithm = "manifest-keyed-aes-256-ecb-lz4-or-aes-counter-stream";
        output = Aion2DatFileEncryption.DecryptDataTable(data, path);
    }
    else if (lower.Contains("/data/mapdatahierarchy/"))
    {
        (family, algorithm) = ("map-hierarchy", "none-plain-binary");
        output = data;
        json = JsonConvert.SerializeObject(new FAion2MapHierarchyFile(file), Formatting.Indented);
    }
    else
    {
        family = lower.Contains("/data/mapevent/") ? "map-event" : lower.Contains("/data/worldmap/") ? "world-map" : "map-data";
        algorithm = "repeating-xor-25-a8-7e-91";
        output = (byte[]) data.Clone();
        FAion2DatFileArchive.DecryptData(output);
        if (family == "map-event") json = Encoding.UTF8.GetString(output);  // map events are JSON text
    }

    var relativeBin = Path.ChangeExtension(path, ".bin");
    var binPath = Path.Combine(decryptedRoot, relativeBin.Replace('/', Path.DirectorySeparatorChar));
    Directory.CreateDirectory(Path.GetDirectoryName(binPath)!);
    File.WriteAllBytes(binPath, output);
    var jsonRelative = "";
    if (json is not null)
    {
        var jsonPath = Path.ChangeExtension(binPath, ".json");
        File.WriteAllText(jsonPath, json, new UTF8Encoding(false));
        jsonRelative = Path.GetRelativePath(outputRoot, jsonPath).Replace('\\', '/');
    }
    var container = file is VfsEntry entry ? entry.Vfs.Name : "";
    return [path, family, algorithm, container,
        Path.GetRelativePath(outputRoot, binPath).Replace('\\', '/'), output.Length.ToString(),
        Convert.ToHexString(SHA256.HashData(output)), json is null ? "binary-only" : "json", jsonRelative];
}

static string Csv(IEnumerable<string> values) => string.Join(",", values.Select(v => "\"" + v.Replace("\"", "\"\"") + "\""));

static Dictionary<string, string> ParseArguments(string[] arguments)
{
    var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    for (var i = 0; i < arguments.Length; i++)
    {
        if (!arguments[i].StartsWith("--")) throw new ArgumentException($"Unexpected argument: {arguments[i]}");
        var name = arguments[i][2..];
        result[name] = i + 1 < arguments.Length && !arguments[i + 1].StartsWith("--") ? arguments[++i] : "true";
    }
    return result;
}

static string Required(Dictionary<string, string> options, string name) =>
    options.TryGetValue(name, out var value) ? value : throw new ArgumentException($"Missing --{name}");
