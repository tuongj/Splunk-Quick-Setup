#!/bin/bash
# Author: Jimmy Tuong
# E-mail: tuongj@gmail.com
clear

# Splunk installation directory
SPLUNK_HOME="/opt/splunk"

# Splunk system local directory
SYS_LOCAL="$SPLUNK_HOME/etc/system/local"

# User defined indexers
INDEXER=""

# User defined indexers receiving port (default 9997)
RECV_PORT=9997

# User defined management port (default 8089)
MGMT_PORT=8089

# Defines the maximum number of open file descriptors
MAX_FILE_DESCRIPTOR=8192

# Defines the maximum number of processes available to a single user
MAX_PROCESSES_USER=1024

# Defines the maximum size of a process's data segment
MAX_DATA_SEGMENT=1073741824

# Defines the user to install Splunk
USER="splunk"

# Defines the group to install Splunk
GROUP="splunk"

# Splunk tar file download link via wget
# Example: AGENT_DOWNLOAD_LINK="https://www.splunk.com/bin/splunk/DownloadActivityServlet?architecture=x86_64&platform=linux&version=6.6.3&product=universalforwarder&filename=splunkforwarder-6.6.3-e21ee54bc796-Linux-x86_64.tgz&wget=true"
AGENT_DOWNLOAD_LINK=""

# Finds Splunk .rpm package
SPLUNK_PACKAGE=$(find /opt/ -name "splunk-*.rpm" | sort -r)

##########################################


splunk_options() {
	read -p "Install options:
	1 - Indexer
	2 - Search Head
	3 - Forwarder
Please select a number (1-3): " user_sel
}

splunk_options
while [[ ! $user_sel =~ ^[1-3] ]]; do
	echo -e "ERROR: $user_sel is not an option. Please select again.\n"
	splunk_options
done



##########################################
# Functions 
fail(){
	echo
	echo "ERROR: $@" >&2
	exit 1
}

ask(){
	local loc_var

	while :
	do
		read -p "$1" loc_var

		if [[ $loc_var =~ ^[yYnN]$ ]]; then
			break;
		fi
		echo "ERROR: Please answer y or n" >&2
	done

	echo $loc_var
}

start_splunk(){
	echo "[+] Starting Splunk service"
	chown -R $USER:$GROUP $SPLUNK_HOME
	
	sudo -H -u $USER $SPLUNK_HOME/bin/splunk start --answer-yes --no-prompt --accept-license 2>&1 | tee /opt/splunk-errors.txt

	echo "[+] Enabling Splunk to run at boot"
	sudo $SPLUNK_HOME/bin/splunk enable boot-start -user splunk 2>&1 | tee /opt/splunk-errors.txt
	echo
}

restart_splunk(){
	echo "[+] Restarting Splunk service"
	sudo $SPLUNK_HOME/bin/splunk restart 2>&1 | tee /opt/splunk-errors.txt
}

# Splunk Installation 
install_splunk(){

	test -z "$SPLUNK_PACKAGE" && \
		fail "No Splunk installer detected. Please place the installer in the /opt directory and run the script again."

	counter=$(echo "$SPLUNK_PACKAGE" | wc -l)

	for package in $SPLUNK_PACKAGE
	do
		local input=$(ask "This script will install "$package". Is this correct (y/n)? ")
		
		case $input in
			[yY]) SPLUNK_PACKAGE=$package && break;;
			[nN]) ((counter--));;
		esac

		if [ "$counter" -le "0" ]; then 
			fail "No more Splunk installer detected. Please place the package in the /opt directory and run the script again."
		fi
	done

	# Increase resource limits on *nix systems
	ulimit -n $MAX_FILE_DESCRIPTOR
	echo "[+] Increased the maximum number of open file descriptors to "$MAX_FILE_DESCRIPTOR
	ulimit -u $MAX_PROCESSES_USER
	echo "[+] Increased the maximum number of processes available to a single user to "$MAX_FILE_DESCRIPTOR
	ulimit -d $MAX_DATA_SEGMENT
	echo "[+] Increased the maximum size of a process's data segment to "$MAX_DATA_SEGMENT


	# Install Splunk using default configuration
	chmod 744 $SPLUNK_PACKAGE

	echo "[+] Installing Splunk in $SPLUNK_HOME"
	rpm -i $SPLUNK_PACKAGE 2>&1 | tee /opt/splunk-errors.txt
	if [ -s "/opt/splunk-errors.txt" ]; then
		ERROR="/opt/splunk-errors.txt"
	fi

	if [ -s "$SPLUNK_HOME/bin/splunk" ]; then
		export PATH="$SPLUNK_HOME/bin:$PATH"
		echo "[+] Splunk installation complete"
	else
		fail "Splunk did not install correctly. Please review the error log in $ERROR"
	fi

	# Change ownership of the Splunk home directory
	chown -R $USER:$GROUP $SPLUNK_HOME

	# Enable HTTPS
	LOCAL_WEB=$SYS_LOCAL/web.conf
	cat > $LOCAL_WEB <<-EOF
	[settings]
	enableSplunkWebSSL = true
	EOF

	if [ -s $LOCAL_WEB ]; then
		echo "[+] HTTPS is enabled for Splunk web over port 443. You must now prepend \"https://\" to access Splunk Web."
	fi

}

##########################################
# Indexer/Search Peers
#
# https://docs.splunk.com/Documentation/Splunk/latest/Forwarding/Enableareceiver
echo
if [ "$user_sel" -eq 1 ]; then

while :
do
read -p "Indexer configuration options:
	1 - Install indexer
	2 - Configure license slave

Please select a number (1-2): " idx_opt

	case "$idx_opt" in
		1) break;;
		2) break;;
		*) echo "ERROR: $idx_opt is not an option. Please select again.";;
	esac
done

idx_opt=$idx_opt

	if [ "$idx_opt" -eq 1 ]; then
		install_splunk

		echo "[+] Enabling receiving port on the indexer"
		
		cat > $SYS_LOCAL/inputs.conf <<-EOF
		[splunktcp://9997]
		disabled = 0
		EOF

		echo "[+] Receiving port on the indexer has been set to 9997"
		echo
		start_splunk
	fi

	if [ "$idx_opt" -eq 2 ]; then
		read -p "Specify the host of the splunkd license master instance: " lic_master

		sudo -u $USER $SPLUNK_HOME/bin/splunk edit licenser-localslave -master_uri https://$lic_master:$MGMT_PORT 2>&1 | tee /opt/splunk-errors.txt

	fi

fi

##########################################
# Search Head
#
if [ "$user_sel" -eq 2 ]; then
	
	# Forward search head logs to indexer layer
	if [ -z "$INDEXER" ]; then
		echo "[+] Configuring the search head to forward data to the indexer layer"
		input=$(ask "Have you installed indexer(s) prior to this step? (y/n): ")

		if [[ $input =~ ^[yY] ]]; then
			while :
			do
				read -p "Insert Splunk indexer IP address or domain names. If you have more than one, separate the indexers with a comma (i.e. 192.31.20.2,myHostname): " user_indexer
				read -p "Enter the indexer receiving port (default 9997): "  user_recv_port
				read -p "Enter the indexer management port (default 8089): " user_mgmt_port

				INDEXER=$(echo $user_indexer | sed 's/^[ \t]*//;s/[ \t]*$//')

				if [ -n "$user_recv_port" ]; then
					RECV_PORT=$(echo $user_recv_port | sed 's/^[ \t]*//;s/[ \t]*$//')
				fi
				if [ -n "$user_mgmt_port" ]; then
					MGMT_PORT=$(echo $user_mgmt_port | sed 's/^[ \t]*//;s/[ \t]*$//')
				fi

				echo
				echo "The following indexers have been added:"
				# Prints indexer IP address/hostname
				IFS="," read -ra INDEXES1 <<< "$INDEXER"
				for i in "${INDEXES1[@]}"; do
					echo "$i"
					INDEXES1=("${INDEXES1[@]/$i/$i:$RECV_PORT}")
				done

				INDEXES_RECV=$(IFS="," ; echo "${INDEXES1[*]}")
				break
			done
		elif [[ $input =~ ^[nN] ]]; then
			fail "You must have indexers setup prior to continuing"
		fi
	fi
	
	# Prompt user to designate a license master
	echo
	echo "[+] Configuring Splunk instance as a license slave"
	echo "NOTE: By default, a standalone instance of Splunk is its own license master. Splunk recommends that you have a search head as a license master."
	prompt_first_install=$(ask "Is this your first search head installation instance? (y/n): ")

	if [[ $prompt_first_install =~ ^[yY] ]]; then
		echo
		echo "This Splunk instance will be designated as the license master server. Make note of the IP address/hostname of this instance."
		echo
		read -p "Press any key to continue"
	else
		read -p "Specify the IP address/hostname of the splunkd license master instance: " license_master
		# http://docs.splunk.com/Documentation/Splunk/latest/Admin/LicenserCLIcommands
		$SPLUNK_HOME/bin/splunk edit licenser-localslave -master_uri https://$license_master:$MGMT_PORT 2>&1 | tee /opt/splunk-errors.txt
		
		check_error=$(tail -n1 /opt/splunk-errors.txt | grep 'Unable to connect to license master')

		if [ -z "$check_error" ]; then
			echo "[+] The Splunk instance has been configured as the license slave"
		else
			fail "Could not configured the Splunk instance as the license slave. Review the errors log /opt/splunk-errors.txt for details."
		fi
	fi


	if [ -n "$SPLUNK_HOME" ]; then		
		# http://docs.splunk.com/Documentation/Splunk/latest/DistSearch/Configuredistributedsearch

		# Installs Splunk instance
		install_splunk
		start_splunk

		# Adds search peers to the search head for distributed search
		SP_ACCT="admin"
		SP_PASS="changeme"
		for peer in `echo $INDEXES_RECV | grep -oP '^[^:]+' | xargs -d ',' -n1`; do
			echo
			echo "[+] Configuring the Splunk instance to add search peer $peer to the search head"

			if [ $SP_ACCT == "admin" ] && [ $SP_PASS == "changeme" ]; then
				read -p "Enter the username for the search peer $peer (defaults to admin): " peer_acct
				read -s -p "Enter the password for the search peer $peer (defaults to changeme): " peer_pass
				
				if [ -n "$peer_acct" ] || [ -n "$peer_pass" ]; then
					SP_ACCT=$peer_acct
					SP_PASS=$peer_pass
				fi
			else
				echo
				sp_acct_reuse=$(ask "Reuse previous account ($SP_ACCT)? (y/n): ")
				if [[ $sp_acct_reuse =~ ^[nN] ]]; then
					SP_ACCT="admin"
					SP_PASS="changeme"
				fi
			fi

			$SPLUNK_HOME/bin/splunk add search-server https://$peer:$MGMT_PORT -auth admin:changeme -remoteUsername $SP_ACCT -remotePassword $SP_PASS 2>&1 | tee /opt/splunk-errors.txt
		done
	fi

	# Forward search head data to the indexer layer
	cat > $SYS_LOCAL/outputs.conf <<-EOF
	# Turn off indexing on the search head
	[indexAndForward]
	index = false

	[tcpout]
	defaultGroup = search_peers
	forwardedindex.filter.disable = true
	indexAndForward = false

	[tcpout:search_peers]
	server = $INDEXES_RECV
	autoLB = true
	EOF

	restart_splunk

fi



##########################################
# Universal Forwarder
#
# https://docs.splunk.com/Documentation/Forwarder/latest/Forwarder/Installanixuniversalforwarderremotelywithastaticconfiguration

if [ "$user_sel" -eq 3 ]; then

	SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
	HOSTS_FILE="$SCRIPT_DIR/host_file.log"
	AGENT_FILE="$(find $SCRIPT_DIR -name "splunkforwarder*.tgz" | sort -r )"
	DEPLOY_SERV=""
	AGENT_PARENT="/opt"

	echo "##################"
	echo "#"
	echo "# Prerequisites"
	echo "#"
	echo "##################"
	echo "1. The file, host_file.log, must be created in the $SCRIPT_DIR directory. It must be populated with a list of hosts."
	echo -e "Example of host_file.log contents:\nserver1\nserver2.foo.lan\nyou@server3\n10.2.3.4"
	echo
	echo "2. Download link to the Splunk Universal Forwarder TAR file. Update the variable AGENT_DOWNLOAD_LINK on the script to reflect the direct download link."
	echo

	test -s "$HOSTS_FILE" || \
		fail "host_file.log missing in $SCRIPT_DIR. Populate the host_file.log before proceeding."

	test -f "$AGENT_DOWNLOAD_LINK" || \
	  	fail "Variable AGENT_DOWNLOAD_LINK is empty. Update the variable AGENT_DOWNLOAD_LINK on the script to reflect the direct download link."

	user_deploy_sel=$(ask "Do you have a deployment server you wish to use? (y/n): ")

	if [[ $user_deploy_sel =~ ^[yY] ]]; then
		read -p "Specify the host and management (not web) port of the deployment server (i.e. deploymentServer:8089) that will be managing these forwarder instances (defaults to none): " user_deploy_serv
		DEPLOY_SERV=$user_deploy_serv
	fi

	if [ -n $DEPLOY_SERV ]; then
		ESTAB_DEPLOY_SERV="sudo $AGENT_PARENT/splunkforwarder/bin/splunk set deploy-poll $DEPLOY_SERV --answer-yes --no-prompt --accept-license --auto-ports"
	fi

	REMOTE_SCRIPT="cd /opt; sudo wget -O splunkforwarder.tgz '$AGENT_DOWNLOAD_LINK'; sudo tar -zxf $AGENT_FILE -C $AGENT_PARENT; $ESTAB_DEPLOY_SERV ; sudo chown -R root:root /opt/splunkforwarder; sudo $AGENT_PARENT/splunkforwarder/bin/splunk start --answer-yes --no-prompt --accept-license --auto-ports; sudo rm -rf $AGENT_FILE"

	ACCOUNT=""
	for host in `cat $HOSTS_FILE`; do
		echo
		echo "##############################################"
		echo "#"
		echo "# Starting the forwarder process on $host"
		echo "#"
		echo "##############################################"
		echo

		if [ -z "$ACCOUNT" ]; then
			read -p "Enter username for $host: " user_acct
			ACCOUNT=$user_acct
		else
			user_acct_reuse=$(ask "Reuse previous account ($ACCOUNT)? (y/n): ")
			if [[ $user_acct_reuse =~ ^[nN] ]]; then
				ACCOUNT=""
			fi
		fi

		echo "[+] Running remote script..."
		ssh -t $ACCOUNT@$host $REMOTE_SCRIPT
	done

fi