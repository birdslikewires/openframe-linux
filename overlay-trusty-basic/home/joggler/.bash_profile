
if [ $(tty) == /dev/tty1 ]; then
	
	countdown() {
		MSG="$1"
		SEC=$2
		tput civis
		while [ $SEC -gt 0 ]; do
			echo -ne "$MSG in $SEC\033[0K\r"
			sleep 1
			: $((SEC--))
		done
		echo -e "$MSG now..."
		tput cnorm
	}

	droptoshell() {

		counter=10
		counterest=$((counter*2))

		echo -n "Stalling for network (up to $counterest seconds)..."
		until ping -c 1 -W 1 8.8.8.8 &>/dev/null
		do
			[ $counter -eq 0 ] && break
			sleep 1;
			let counter-=1
		done

		if [ $counter -eq 0 ]; then
			NETWORKUP=0
			echo " not available."
			echo
			countdown "Moving on" $1
			sleep 1
		else
			NETWORKUP=1
			echo " network ready."
			echo -n "Fetching network time..."
			ntpdate 0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org 2>&1 >/dev/null
			echo " done."
			sleep 1
			echo
			echo -n "eth0: "
			ifconfig eth0 | grep inet | grep -v inet6 | sed 's/^ *//'
			tput sgr0
			echo
		fi

	}

	echo
	droptoshell 3
	
fi
