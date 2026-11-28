The Bible Maker 2.0.0.005 for Linux (64-bit)
============================================

Built for Debian 12 (bookworm) and Debian 13 (trixie) on 64-bit PCs
(x86_64). It also runs on Ubuntu and other Debian-based systems.


How to run it
-------------
1. Extract this folder anywhere in your home folder, for example
   ~/Apps/TheBibleMaker. Keep all the files in it together.
2. Open the folder and double-click "iBiblia" (transition executable for
   v2.0.0.002). If double-clicking does not start it, open a terminal in
   the folder and type:   ./iBiblia
3. Optional: to add The Bible Maker to your applications menu, open a
   terminal in the folder and type:   ./install-menu-entry.sh
   (Run it again if you ever move the folder.)


If it does not start
--------------------
It needs the GTK2 and SQLite libraries. Most Debian desktops already
have them. If not, open a terminal and type:

   Debian 12:  sudo apt install libgtk2.0-0 libsqlite3-0
   Debian 13:  sudo apt install libgtk2.0-0t64 libsqlite3-0

The PCRE library (libpcre.so.3) is included in this folder, because
Debian 13 no longer ships it.


Optional features
-----------------
- Reading words aloud (Tools > Voice settings) needs a speech engine:
     sudo apt install espeak-ng
- The AI-assisted engine and direct GitHub publisher use OpenSSL
  (libssl3) and certificates (ca-certificates), which Debian installs by
  default.


Your settings and projects
--------------------------
- Projects use `.tbm` (and legacy `.bib` files remain supported) across Windows and Linux.
- Settings are saved in ~/.config/TheBibleMaker/TheBibleMaker.ini (and
  migrate automatically from ~/.config/iBiblia/iBiblia.ini or an
  adjacent iBiblia.ini on first run).
- Dictionary paths in Windows INIs point to Windows folders, so choose
  your dictionaries again in Tools > Default dictionaries if copied from
  Windows.


Licences
--------
The Bible Maker's own additions are licensed under AGPL-3.0-or-later
(see LICENSE). The original iBiblia code remains the copyright of
Rúbio R. C. Terra (see NOTICE.md).
Third-party notices are in THIRD-PARTY-NOTICES.txt and the licenses
folder (PCRE, SQLite, OpenSSL, Mozilla CA list).
