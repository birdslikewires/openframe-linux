
# Fire up the reflashing script.
if [ $(tty) == /dev/tty1 ]; then
  sudo /usr/local/bin/offlash start
fi
