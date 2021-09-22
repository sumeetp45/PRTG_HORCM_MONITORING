            ********** Readme **********

PRTG - HORCM replication monitoring + monitoring of the horcm processes
***************************************************************************

Copy the following files:

1. prtg_horcm_mon_v1.pl in /root or any other location. 
2. prtg_horcm_monitor.sh in /var/prtg/scriptsxml/
3. prtg_horcm_replication.sh in /var/prtg/scriptsxml/

***************************************************************************

This monitoring requires Perl to be installed on the horcm server. 
This script is tested with the following Perl versions, but should work with the latest versions too

/usr/bin/perl -v

This is perl, v5.10.1 (*) built for x86_64-linux-thread-multi

Copyright 1987-2009, Larry Wall

Perl may be copied only under the terms of either the Artistic License or the
GNU General Public License, which may be found in the Perl 5 source kit.

Complete documentation for Perl, including FAQ lists, should be found on
this system using "man perl" or "perldoc perl".  If you have access to the
Internet, point your browser at http://www.perl.org/, the Perl Home Page.

***************************************************************************

This script has been tested on the following version of Linux.
But should work across other version too.

uname -a
Linux c1064-horcm 2.6.32-696.28.1.el6.x86_64 #1 SMP Thu Apr 26 04:27:41 EDT 2018 x86_64 x86_64 x86_64 GNU/Linux

***************************************************************************

Since I have copied the files on windows to be able to upload them to GitHub, the files will have extra ^M character
or similar at the end of each line. 
Once you copy the files to Linux server, remove these extra characters at end of each line.

***************************************************************************

Steps on how to configure the PRTG sensor

1. Add the HORCM server in PRTG monitoring
2. Once the server is discovered in PRTG, go to the settings of the server and 
    in Credentials for Linux/Solaris/macOS (SSH/WBEM), provide the root user access 
    and password. 
3. Select add a new sensor on the HORCM server. Search for SSH Script Advanced sensor
4. Provide a sensor name
    a. In case of horcm process monitoring, a single sensor is sufficient to monitor all processes
    b. In case of Consistency group replication, a sensor is required for each CG
5. The script drop down should list prtg_horcm_monitor.sh and prtg_horcm_replication.sh
    a. Make sure the scripts are already copied on to the horcm server
6. In the parameter section, provide the -hid <horcm-id>
    a. In case of process monitoring, you need to provide all the processes you need to monitor
    b. In case of replication monitoring, just provide the horcm id on the local horcm server
    
***************************************************************************

Example:

There are two CGs replicating. CG1 with horcm ID 220 and CG2 has horcm ID 221

To configure the horcm process monitoring, the parameter in PRTG should have the input as '-hid 220 -hid 221', everything in the same line

To configure the horcm replication monitoring, you need to create two sensors.
The first for CG1 (sensor name can be CG1) and the parameter in PRTG should have the input as '-hid 220'
The second sensor for CG2 (sensor name can be CG2) and the parameter in PRTG should have the input as '-hid 221'

***************************************************************************
