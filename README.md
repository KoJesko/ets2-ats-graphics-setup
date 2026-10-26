# ETS2 / ATS graphics setup

One script that installs, switches or removes graphics mods for **Euro Truck Simulator 2** and **American Truck Simulator**:

| # | Option | What ends up in `bin\win_x64` |
|---|--------|-------------------------------|
| 1 | DLSS 5 | ReShade + DLSS 5 (DLSS 5 runs as ReShade add-ons) |
| 2 | Snowymoon | Snowymoon lighting (`dxgi.dll` + `dinput8.dll`) |
| 3 | ReShade | ReShade only |
| 4 | All | ReShade → Snowymoon chain + DLSS 5 |
| 5 | All but DLSS 5 | ReShade → Snowymoon chain |
| 6 | Remove all | Back to vanilla |

When you pick Snowymoon without DLSS 5 (2 or 5), the script also asks whether you want Snowymoon's DLSS 3.7. With DLSS 5, its newer `nvngx_dlss.dll` replaces Snowymoon's.

## Run it

Open PowerShell and paste:

```powershell
irm https://raw.githubusercontent.com/KoJesko/ets2-ats-graphics-setup/main/install.ps1 | iex
```

It finds ETS2 and ATS in your Steam libraries and asks which game to set up. Close the game first. Run it again any time to switch to a different option.

## Works with HaulMP

Every mod loads through the game folder's own DLL chain. Nothing is injected into the game:

```
eurotrucks2.exe -> dxgi.dll (ReShade) -> dxgi2.dll (Snowymoon) -> Windows dxgi.dll
                   dinput8.dll (Snowymoon)
```

ReShade's `ReShade.ini` gets `[PROXY] ProxyLibrary=.\dxgi2.dll` so it hands over to Snowymoon.

Some older HaulMP workarounds injected a second copy of ReShade (`ReShade64.dll`). With two ReShades loaded, the `dxgi.dll` one shuts itself down, DirectX 11 fails and the game hangs with no window. The script removes stray `ReShade64.dll` / `SnowyMoon64.dll` copies and any startup item running `inject-reshade`.

## Where the files come from

Nothing third-party is stored in this repo. The script downloads from the official sources:

| Part | Source |
|------|--------|
| ReShade 6.8.0 (add-on build) | [reshade.me](https://reshade.me), checksum verified |
| ReShade shaders | [crosire/reshade-shaders](https://github.com/crosire/reshade-shaders) (`slim` branch), only if `reshade-shaders` is missing |
| Snowymoon lighting v2 | [snowymoon.io](https://snowymoon.io/?dl=v2), newest version listed there |
| Snowymoon DLSS 3.7 | snowymoon.io (`dlss_3.7.zip`) |
| NVIDIA Streamline + DLSS 310.9 | [NVIDIA-RTX/Streamline](https://github.com/NVIDIA-RTX/Streamline/releases) v2.14.16 (~280 MB, once) |

Snowymoon is free to download and asks for its activation key the first time the game starts.

### DLSS 5 files you supply yourself

These have no public download link, so the script asks for a folder that has them:

- `nvngx_dlssnr.dll` (required)
- `renodx-dlss.addon64` and/or `dlss5-bridge.addon64` (at least one)
- `dlss5-bridge.cfg` (optional)

It also looks in a `dlss5` folder next to the script and in your Downloads folder. After the first time it keeps a copy in `%LOCALAPPDATA%\TruckGfxSetup\dlss5`, so it won't ask again. If the files aren't found, DLSS 5 is skipped and everything else is still installed.

## Backups and cache

- Downloads are cached in `%LOCALAPPDATA%\TruckGfxSetup\cache`.
- Before changing a game folder, the script removes every DLL it manages and then puts back what you chose. A removed file with an identical copy in the cache is deleted. Anything else, including an unknown `dxgi.dll` or `dinput8.dll` from another mod, is moved to `%LOCALAPPDATA%\TruckGfxSetup\backup\<game>\<time>`.
- `ReShade.ini`, `reshade-shaders`, Snowymoon's settings and `dlss5-bridge.cfg` are kept. Your ReShade preset and settings survive a switch.

If the game folder can't be written to, run PowerShell as administrator.

## Licence

The script is MIT licensed (see [LICENSE](LICENSE)). ReShade, Snowymoon, RenoDX, DLSS 5 Bridge and NVIDIA Streamline/DLSS belong to their authors and are under their own terms.
