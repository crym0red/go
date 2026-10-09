# MRzefvGC
Dylib for re-signed games that hard-require Game Center (e.g. error 5019 / "Game Center Login Required").
- Fakes an authenticated GKLocalPlayer.
- Rewrites PlayFab LoginWithGameCenter to LoginWithCustomID (guest account per install).
Build: push to GitHub, Actions builds, grab MRzefvGC.dylib from Releases > latest.
Use: inject MRzefvGC.dylib when signing (zsign -l), install, launch.
Works only if the game's PlayFab title allows custom-ID account creation.
