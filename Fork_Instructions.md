Installation instructions:
For this to be tested:
1 - You need to enable the gamelist.xml config in ES-DE
2 - You also need to enable the "Enable Custom event Script"ing" in ES-DE
3 - You need to put the esde-game-start-remotedownload.sh file in $rd_home/ES-DE/scripts/game-start/ and chmod +x it

I dropped a quick "drop this at your home" for a quick test on a fresh install, just make sure to chmod the script.


Features:
- New menues in the retrodeck configurator that allows to connect to a webdav server
- Auto discovery of systems presents in the webdav server and fetching or creating gamelist.xml from this (the file used by ES-DE to show roms)
- Automatic download of remote files when launched in the ES-DE interface
- Automatic launch after the download of the remote roms (the user experience is smooth on that front)

Issues:
- If you download a rom outside Retrodeck and not part of those present in the remote server locally, it will not be detected by ES-DE and will never appear for now
- You need to relaunch retrodeck once or use the utilities menu to redetect roms after any sync or change of the configuration
- Auto refresh of all gamelists (remote & local) at retrodeck startup is currently not implemented