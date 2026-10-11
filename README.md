# AION2 client data decoding

> **Educational purposes only.** This repository is a study of the AION2 client's data formats
> and network protocol. It contains **no game client, no game files and no extracted game data**.
> Everything the tools produce comes from a copy of AION2 that you install and own. It is not
> affiliated with or endorsed by NCSOFT; AION2 and its assets belong to their owners. Do not use
> it to connect to, disrupt or impersonate official services, and respect the game's terms of
> service.

Extract the AION2 client installed on your PC, decrypt its data tables, decode them, and build a
MySQL/MariaDB database from them.

```powershell
copy config\database.example.ini config\database.ini        # then fill in your connection
.\Extract-GameData.ps1 -GameDirectory 'D:\Games\AION2'        # extract, decrypt, decode
.\Import-GameDataToDatabase.ps1                               # create the database
```

`.\Build-GameDatabase.ps1` runs both. Without `-GameDirectory` the client is looked up in your
Steam libraries.

| Script | Does |
| --- | --- |
| `Extract-GameData.ps1` | Client paks → raw files → decrypted `.bin` tables → decoded JSON |
| `Import-GameDataToDatabase.ps1` | Decoded JSON → the database in `config/database.ini` |
| `Build-GameDatabase.ps1` | Both, in order |
| `Setup-Dependencies.ps1` | Fetches and builds what the extraction needs (run automatically) |

All data comes from your own client installation.

## Client version

All formats, table layouts, keys and protocol notes were verified against this client:

| | |
| --- | --- |
| Game | AION 2, global release (Steam app 3393110) |
| Steam build | 25800038, updated 2026-10-09 |
| Table layouts | October 2026 (`tools/client-data/october/october-2026-schema.json`) |
| Unreal type mappings | `dependencies/AION2-5.3.2.0.usmap` |
| Archive AES key | `config/client-data-aes-key.txt` |

Other client versions may use another key or changed table layouts; the tools report what no
longer decodes instead of importing wrong data.

The local server that uses this database is
[Aion2_Server_Example](https://github.com/SemaAlter/Aion2_Server_Example).

## Requirements

- An AION2 installation
- git, .NET 10 SDK, Visual Studio C++ build tools (CUE4Parse builds a native helper)
- Python 3.9+ (standard library only)
- A MySQL or MariaDB server, and its `mysql.exe` client (`-MySqlPath`, default
  `C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe`)

`Setup-Dependencies.ps1` clones [CUE4Parse](https://github.com/FabianFG/CUE4Parse) into
`external/` at the pinned commit `ec6595e`, applies the AION2 patches from `dependencies/`, and
builds `Aion2Extractor`. CUE4Parse downloads the Oodle and zlib-ng DLLs on the first
extraction.

## Configuration

| File | Purpose |
| --- | --- |
| `config/database.ini` | Your connection: host, port, user, password, database name. Copy it from `database.example.ini`. The database is created if missing. |
| `config/client-data-aes-key.txt` | AION2 archive AES key. `-AesKey 0x...` overrides it after a client update. |

## Extract-GameData.ps1

1. `Aion2Extractor` mounts every `.pak`, `.utoc` and `.ucas` container with the archive AES key
   and writes each virtual file unchanged to `output/raw/` (`-RawDirectory` to put it elsewhere).
   Files already present with the same size are skipped on reruns.
2. It decrypts every AION2 `.dat` (key manifest, BLAKE3-keyed AES tables, localization, XOR maps
   and map events) into `output/decrypted/**.bin`, writes JSON for localization, map events, the
   map hierarchy and the key manifest, and lists every file in `output/decryption-manifest.csv`
   (container, algorithm, size, SHA-256).
3. `tools/client-data/october/export.py` decodes the `.bin` tables, startup tables, maps and world
   maps into `output/decoded/` (JSON).

`-DataOnly` limits step 1 to `Content/Data`, `StartUpData`, `L10N` and `.dat` files (about 2,400
of 900,000 files). A full extraction needs 100+ GB of free space. Errors are listed in
`output/extract-errors.txt`.

## Import-GameDataToDatabase.ps1

1. `catalogs.py`: items, NPCs, monsters, spawns, quests, maps, loot, events, environment objects
2. `tools/Import-Aion2GameData.ps1`: skills
3. `tools/Initialize-GameDatabase.ps1`: database, schema, catalogs, client table manifest
4. `tools/Import-StructuredClientData.ps1`: every decoded table and map as `client_data_records`
5. `client_tables.py`: one `ct_*` table per client table, with localized names

Everything comes from the client. It ships no NPC combat stats, so `monsters` rows carry
placeholder stats derived from level and rank (`catalogs.py`).

## After a client update

The table layouts in `tools/client-data/october/october-2026-schema.json` match the client
version above. Tables whose layout changed are listed in
`output/decoded/audit.csv` and skipped by the import.
