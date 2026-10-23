# ForeverAuras
ForeverAuras is a powerful and flexible framework that allows the display of highly customizable graphics on World of Warcraft's user interface to indicate buffs, debuffs, and other relevant information. This addon was created to be a replacement for WeakAuras2 in WoW Forever.

## Quick Start
To open the options window, type `/fa` or `/foreverauras` into your chat and hit enter or use the minimap icon.

## FAQ
### Q: I thought Blizzard disabled addons for WoW Forever just like Retail?
*A: Addons are not disabled they just work differently now. There are "Secret" APIs which cannot be controlled by addons. Blizzard controls these APIs but Addons can tell them how to be displayed through the Blizzard CDM (Cooldown Manager). To see Blizzard's CDM, type `/cdm` in game chat.*

### Q: What is the Blizzard Cooldown Manager (CDM)?
*A: The CDM in WoW Forever is intended to enhance gameplay by pulling critical information from the buff bar or action bar and placing it in a fully customizable location. By default, the Cooldown Manager is disabled, and it can be enabled in Options under the Gameplay Enhancement settings.*

### Q: I thought WeakAuras are dead. Why should I download ForeverAuras?
*A: WeakAuras is only "dead" because the WA devs have decided not to update the addon.
Myself and a few others have spent a considerable amount of time to update the WeakAuras addon to work in WoW Forever. This is posted as a new addon [ForeverAuras](<https://www.curseforge.com/wow/addons/foreverauras>) and follows the license posted by WeakAuras.*

### Q: Will my old WeakAuras imports work in ForeverAuras?
*A: It depends on what the WeakAura is doing. Certain things are no longer accessible in Combat but most out of combat WeakAuras should work.*

### Q: I have a question about how to accomplish something in the ForeverAuras addon
*A: You can ask the community for help in our Discord. The Discord link is in the footer of the in-game addon.*

### Q: What's up with Modern Auras not being able to do `xyz`?
*A: Think of a Modern aura icon as a picture the game draws for you, not one the addon draws. During a fight, the game locks that picture: addons can look at it but can't touch it. So anything the addon figures out on its own (like "you're out of range") can't be painted onto that icon until the fight ends, and that's when it catches up.*

*The only exceptions are the 'Aura Active' conditions, because the game itself paints those when it draws the icon.*

*Old-style (Legacy) icons are drawn by the addon, so those can be recolored mid-fight, but they can't see auras in combat anymore, which is why you switched to Modern in the first place. You can't have both on one icon. The workaround is a second, addon-drawn thing laid over the top, like a red square that appears when you're out of range. This is what still makes ForeverAuras incredibly strong and powerful compared to any other aura displaying mechanism; the Addon still allows for complete customization; you just need to understand the limitations.*

## Acknowledgements

This project is a modified version of [WeakAuras2](https://github.com/WeakAuras/WeakAuras2).

- Original work - Copyright © Stanzilla

This modified version is licensed under the GNU General Public License, version 2.0.

- Modifications and additions - Copyright © 2026 Neroxrw
- See [LICENSE](https://github.com/neroxrw/foreverauras/blob/main/LICENSE) for the complete GPL-2.0 license.

This project also includes code from [M33kAuras](https://github.com/m33shoq/M33kAuras).