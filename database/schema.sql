SET GLOBAL local_infile = ON;

CREATE TABLE IF NOT EXISTS schema_versions (
    version INT UNSIGNED NOT NULL PRIMARY KEY,
    description VARCHAR(255) NOT NULL,
    applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS maps (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    walk_mesh_path VARCHAR(1024) NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS skills (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    max_level SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    cooldown_ms INT UNSIGNED NOT NULL DEFAULT 0,
    cast_time_ms INT UNSIGNED NOT NULL DEFAULT 0,
    skill_range FLOAT NOT NULL DEFAULT 0,
    target ENUM('self','friendly','hostile','ground') NOT NULL DEFAULT 'hostile',
    hit_shape ENUM('single','radius','frontal_cone') NOT NULL DEFAULT 'single',
    max_targets SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    angle_degrees FLOAT NOT NULL DEFAULT 0,
    source_table VARCHAR(255) NULL,
    source_payload JSON NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS skill_effects (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    skill_id INT UNSIGNED NOT NULL,
    effect_index SMALLINT UNSIGNED NOT NULL,
    effect_type VARCHAR(128) NOT NULL,
    value_expression VARCHAR(1024) NULL,
    target_filter_id INT UNSIGNED NULL,
    source_payload JSON NULL,
    UNIQUE KEY uq_skill_effect (skill_id, effect_index),
    CONSTRAINT fk_skill_effect_skill FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS items (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    category ENUM('unknown','weapon','armor','consumable','quest','material') NOT NULL DEFAULT 'unknown',
    max_stack INT UNSIGNED NOT NULL DEFAULT 1,
    required_level SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    source_table VARCHAR(255) NULL,
    source_payload JSON NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS npcs (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    kind ENUM('ambient','merchant','quest','teleporter','monster') NOT NULL DEFAULT 'ambient',
    level SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    faction ENUM('neutral','elyos','asmodian') NOT NULL DEFAULT 'neutral',
    interaction VARCHAR(255) NOT NULL DEFAULT '',
    source_table VARCHAR(255) NULL,
    source_payload JSON NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS monsters (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    npc_id INT UNSIGNED NOT NULL,
    monster_rank ENUM('normal','elite','boss') NOT NULL DEFAULT 'normal',
    max_health BIGINT UNSIGNED NOT NULL,
    attack_value INT UNSIGNED NOT NULL,
    defense_value INT UNSIGNED NOT NULL,
    aggro_radius FLOAT NOT NULL,
    move_speed FLOAT NOT NULL,
    attack_range FLOAT NOT NULL,
    server_skill_id INT UNSIGNED NOT NULL,
    attack_interval_ms INT UNSIGNED NOT NULL DEFAULT 1500,
    CONSTRAINT fk_monster_npc FOREIGN KEY (npc_id) REFERENCES npcs(id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS npc_skills (
    npc_id INT UNSIGNED NOT NULL,
    skill_id INT UNSIGNED NOT NULL,
    priority SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    cooldown_override_ms INT UNSIGNED NULL,
    PRIMARY KEY (npc_id, skill_id),
    CONSTRAINT fk_npc_skill_npc FOREIGN KEY (npc_id) REFERENCES npcs(id) ON DELETE CASCADE,
    CONSTRAINT fk_npc_skill_skill FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS spawns (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    template_id INT UNSIGNED NOT NULL,
    kind ENUM('npc','monster') NOT NULL,
    map_id INT UNSIGNED NOT NULL,
    x FLOAT NOT NULL,
    y FLOAT NOT NULL,
    z FLOAT NOT NULL,
    heading FLOAT NOT NULL DEFAULT 0,
    respawn_seconds INT UNSIGNED NOT NULL DEFAULT 0,
    event_id INT UNSIGNED NULL,
    INDEX ix_spawn_map (map_id),
    INDEX ix_spawn_template (kind, template_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS loot_tables (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS loot_table_entries (
    loot_table_id INT UNSIGNED NOT NULL,
    item_id INT UNSIGNED NOT NULL,
    minimum_count INT UNSIGNED NOT NULL DEFAULT 1,
    maximum_count INT UNSIGNED NOT NULL DEFAULT 1,
    chance FLOAT NOT NULL DEFAULT 1,
    PRIMARY KEY (loot_table_id, item_id),
    CONSTRAINT fk_loot_entry_table FOREIGN KEY (loot_table_id) REFERENCES loot_tables(id) ON DELETE CASCADE,
    CONSTRAINT fk_loot_entry_item FOREIGN KEY (item_id) REFERENCES items(id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS quests (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    minimum_level SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    faction ENUM('neutral','elyos','asmodian') NOT NULL DEFAULT 'neutral',
    repeatable BOOLEAN NOT NULL DEFAULT FALSE,
    source_payload JSON NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS quest_objectives (
    quest_id INT UNSIGNED NOT NULL,
    objective_index SMALLINT UNSIGNED NOT NULL,
    objective_type VARCHAR(64) NOT NULL,
    target_id INT UNSIGNED NULL,
    required_count INT UNSIGNED NOT NULL DEFAULT 1,
    payload JSON NULL,
    PRIMARY KEY (quest_id, objective_index),
    CONSTRAINT fk_quest_objective_quest FOREIGN KEY (quest_id) REFERENCES quests(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS quest_rewards (
    quest_id INT UNSIGNED NOT NULL,
    reward_index SMALLINT UNSIGNED NOT NULL,
    item_id INT UNSIGNED NULL,
    item_count INT UNSIGNED NOT NULL DEFAULT 0,
    experience BIGINT UNSIGNED NOT NULL DEFAULT 0,
    currency BIGINT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (quest_id, reward_index),
    CONSTRAINT fk_quest_reward_quest FOREIGN KEY (quest_id) REFERENCES quests(id) ON DELETE CASCADE,
    CONSTRAINT fk_quest_reward_item FOREIGN KEY (item_id) REFERENCES items(id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS world_events (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    map_id INT UNSIGNED NOT NULL,
    trigger_type VARCHAR(64) NOT NULL,
    trigger_value VARCHAR(1024) NOT NULL DEFAULT '',
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    source_payload JSON NULL,
    INDEX ix_world_event_map (map_id, enabled)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS world_event_actions (
    event_id INT UNSIGNED NOT NULL,
    action_index SMALLINT UNSIGNED NOT NULL,
    action_type VARCHAR(64) NOT NULL,
    delay_ms INT UNSIGNED NOT NULL DEFAULT 0,
    payload JSON NOT NULL,
    PRIMARY KEY (event_id, action_index),
    CONSTRAINT fk_event_action_event FOREIGN KEY (event_id) REFERENCES world_events(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS client_data_tables (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    virtual_path VARCHAR(1024) NOT NULL,
    family VARCHAR(64) NOT NULL,
    schema_version INT NULL,
    row_count INT UNSIGNED NULL,
    sha256 CHAR(64) NULL,
    imported_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_client_data_path (virtual_path(768))
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS client_data_records (
    table_id BIGINT UNSIGNED NOT NULL,
    record_key VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    payload JSON NOT NULL,
    PRIMARY KEY (table_id, record_key),
    CONSTRAINT fk_client_record_table FOREIGN KEY (table_id) REFERENCES client_data_tables(id) ON DELETE CASCADE
) ENGINE=InnoDB;

ALTER TABLE client_data_records
    MODIFY record_key VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL;

INSERT INTO schema_versions(version, description) VALUES (1, 'Initial game-data schema')
ON DUPLICATE KEY UPDATE description=VALUES(description);

INSERT INTO schema_versions(version, description) VALUES (2, 'Preserve case- and accent-distinct client-data record keys')
ON DUPLICATE KEY UPDATE description=VALUES(description);

CREATE TABLE IF NOT EXISTS env_objects (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    usage_type VARCHAR(64) NOT NULL,
    usage_value VARCHAR(255) NOT NULL DEFAULT '',
    interact_range INT UNSIGNED NOT NULL DEFAULT 0,
    interact_time_ms INT UNSIGNED NOT NULL DEFAULT 0,
    source_payload JSON NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS env_object_spawns (
    id INT UNSIGNED NOT NULL PRIMARY KEY,
    env_object_id INT UNSIGNED NOT NULL,
    map_id INT UNSIGNED NOT NULL,
    x FLOAT NOT NULL,
    y FLOAT NOT NULL,
    z FLOAT NOT NULL,
    heading FLOAT NOT NULL DEFAULT 0,
    INDEX ix_env_spawn_map (map_id),
    CONSTRAINT fk_env_spawn_object FOREIGN KEY (env_object_id) REFERENCES env_objects(id)
) ENGINE=InnoDB;

-- Derived from client data on every import; recreated so its shape can change between schema versions.
DROP TABLE IF EXISTS loot_owners;
CREATE TABLE loot_owners (
    owner_table VARCHAR(64) NOT NULL,
    owner_key VARCHAR(255) NOT NULL,
    owner_id BIGINT NULL,
    owner_kind ENUM('npc','env_object','dungeon','item','quest','field_event','other') NOT NULL,
    loot_table_id INT UNSIGNED NOT NULL,
    link_field VARCHAR(255) NOT NULL,
    link_source ENUM('client','name_suffix','inferred_zone_group') NOT NULL,
    PRIMARY KEY (owner_table, owner_key, loot_table_id, link_field),
    INDEX ix_loot_owner_id (owner_kind, owner_id),
    CONSTRAINT fk_loot_owner_table FOREIGN KEY (loot_table_id) REFERENCES loot_tables(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS loot_table_links (
    parent_loot_table_id INT UNSIGNED NOT NULL,
    child_loot_table_id INT UNSIGNED NOT NULL,
    chance FLOAT NOT NULL DEFAULT 1,
    item_count INT UNSIGNED NOT NULL DEFAULT 1,
    level_min SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    level_max SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    link_source ENUM('package','decompose','level_scale') NOT NULL,
    PRIMARY KEY (parent_loot_table_id, child_loot_table_id),
    INDEX ix_loot_link_child (child_loot_table_id),
    CONSTRAINT fk_loot_link_parent FOREIGN KEY (parent_loot_table_id) REFERENCES loot_tables(id) ON DELETE CASCADE,
    CONSTRAINT fk_loot_link_child FOREIGN KEY (child_loot_table_id) REFERENCES loot_tables(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS quest_class_rewards (
    quest_id INT UNSIGNED NOT NULL,
    character_class VARCHAR(64) NOT NULL,
    reward_index SMALLINT UNSIGNED NOT NULL,
    item_id INT UNSIGNED NOT NULL,
    item_count INT UNSIGNED NOT NULL DEFAULT 1,
    PRIMARY KEY (quest_id, character_class, reward_index),
    CONSTRAINT fk_quest_class_reward_quest FOREIGN KEY (quest_id) REFERENCES quests(id) ON DELETE CASCADE,
    CONSTRAINT fk_quest_class_reward_item FOREIGN KEY (item_id) REFERENCES items(id)
) ENGINE=InnoDB;

INSERT INTO schema_versions(version, description) VALUES (3, 'Environment objects, loot owners, and class quest rewards from client data')
ON DUPLICATE KEY UPDATE description=VALUES(description);

INSERT INTO schema_versions(version, description) VALUES (4, 'Full loot graph: table links and owners from every client reference')
ON DUPLICATE KEY UPDATE description=VALUES(description);
