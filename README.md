entirely vibecoded
# XMacroWindow

A better macro window for **World of Warcraft: Forever** (client 1.60.1, Interface 16001).

## Features

- Resizable and movable macro window
- Search macros by name and body
- Icon search (by name or file ID)
- Keeps all account macros and a log of deleted macros (restore them later)
- Syntax colouring and character counter in the editor

## Install

Copy the `XMacroWindow` folder into your game's `Interface\AddOns\` folder and `/reload`.

## Commands

| Command | Action |
|---|---|
| `/xmw opt` | Options window |
| `/xmw lock` / `/xmw unlock` | Lock / unlock moving and resizing |
| `/xmw reset position` | Move all addon windows back to default spots |
| `/xmw help` | Command list |

## Credits

- Author: ftkun
- Libraries: LibStub, CallbackHandler-1.0, LibSharedMedia-3.0 (in `Libs/`, under their own licenses)
- Font: Cascadia Mono, SIL Open Font License 1.1 (`Media/Fonts/OFL.txt`)
