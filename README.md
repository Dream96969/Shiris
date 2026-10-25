![Shiris: Iris-based customized shader mod](docs/shiris_logo.png)

# Shiris

**Shiris** is a Fabric-based fork of [Iris Shaders](https://github.com/IrisShaders/Iris) for Minecraft 1.21.11. It ships with one embedded shader pipeline, so no external shader pack is required.

## Links

- Download via **[Modrinth](https://modrinth.com/mod/shiris)**
- Download from **[releases](https://github.com/Dream96969/Shiris/tags)**
- Report issues via **[GitHub Issues](https://github.com/Dream96969/Shiris/issues)**

## Installation

1. Install [Fabric Loader](https://fabricmc.net/use/)
2. Download [Sodium](https://modrinth.com/mod/sodium) and place it in your `mods` folder
3. Place the Shiris `.jar` file into your `mods` folder
4. Start Minecraft. The built-in shader is enabled automatically; there is no external shader pack to select.

## Differences from Iris

- Instead of opening external shader packs like Iris, it runs a built-in, embedded pack.
- Designed with a focused structure around a single pack rather than ensuring compatibility across multiple packs.

## Dependencies

| Mod | Required? |
| --- | :---: |
| [Fabric Loader](https://fabricmc.net) ≥ 0.18.1 | ✅ Required |
| [Sodium](https://modrinth.com/mod/sodium) 0.8.x | ✅ Required |

## Build

```bash
./gradlew :fabric:remapJar
```

The distributable JAR is written to `build/libs/shiris-*.jar`.

## License

This project is distributed under the **GNU LGPLv3** license. It is a fork of the original Iris project.

The `glsl-transformer` dependency is licensed under GNU AGPLv3.

Original project: [IrisShaders/Iris](https://github.com/IrisShaders/Iris) — Thank you!
