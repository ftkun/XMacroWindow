entirely vibecoded
# XMacroWindow

A better macro window for **World of Warcraft: Forever** (client 1.60.1, Interface 16001).

## Features

- Resizable and movable macro window
- Search macros by name and body
- Icon search (by name or file ID)
- Keeps all account macros and a log of deleted macros (restore them later)
- XMacro Browser: hover a character in the character dropdown, then use the arrow menu to copy its macros to the current character or delete that character from the list (asks first; only the addon's saved copy is removed)
- Syntax colouring and character counter in the editor
- Ctrl+click an item, recipe, profession or spell (bags, professions window, spellbook, chat links) while the macro window is open to insert its link into the macro, e.g. `/s WTS [Linen Cloth]`. Spell ranks / "(Racial)" go right after the link as plain text (`[Fireball] (Rank 2)`), because the server rejects spell links that include them

## Install

Copy the `XMacroWindow` folder into your game's `Interface\AddOns\` folder and `/reload`.

## Commands

| Command | Action |
|---|---|
| `/xmw opt` | Options window |
| `/xmw lock` / `/xmw unlock` | Lock / unlock moving and resizing |
| `/xmw reset position` | Move all addon windows back to default spots |
| `/xmw links` | Turn ctrl+click links on / off |
| `/xmw help` | Command list |

## Credits

- Author: ftkun
- Libraries: LibStub, CallbackHandler-1.0, LibSharedMedia-3.0 (in `Libs/`, under their own licenses)
- Font: Cascadia Mono, SIL Open Font License 1.1 (`Media/Fonts/OFL.txt`)
