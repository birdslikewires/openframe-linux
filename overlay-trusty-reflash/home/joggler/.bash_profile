
# Fire up the reflashing script.
if [ $(tty) == /dev/tty1 ]; then
  setterm -powersave off
  setterm -blank 0
  sudo -H -u root byobu-select-backend screen
  sudo -H -u root byobu -t "" /usr/local/bin/offlash start
fi
