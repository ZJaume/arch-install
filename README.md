arch-install - Simple Arch Linux Install Script
===============================================

This script was originally forked from
[Tom Wambold's arch-install](https://github.com/tom5760/arch-install)
because I was too lazy to start from scratch, but, even so, it will
be mostly rewritten.
Its purpose is only for personal use and you should not use it unless you know
very well how to install [Arch Linux](https://archlinux.org) or you want to
start your own installation script.

Process
-------

 1. Download an [Arch Linux installer ISO][iso] and boot it on the system you
    want to install.

 2. Download the `arch_install.sh` script to the live system.

        curl -L kutt.it/zj-arch-install > arch-install.sh

 3. Make the `arch_install.sh` script executable.

        chmod +x arch_install.sh

 4. Run the script.

        ./arch_install.sh

 5. If there were no errors, reboot and enjoy!

[iso]: https://www.archlinux.org/download/

Details
-------

This section will, eventually, explain the installation details.
