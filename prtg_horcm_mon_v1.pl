#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;
use JSON;

use Fcntl qw(:flock);

BEGIN { @INC = ("/usr/lib64/perl5/"); }

my $PS = "/bin/ps";
my $GREP = "/bin/grep";

# Avoid global variables
my $prtg_log_file = "/var/prtg/logs/prtg.log";
my $exe_opt_val = "";

# Variables for option monitor_process
my @hrcm_list;
my $hrcm_proc_hash = {};

# Variables for option monitor_replica
my $hid_to_monitor = 0;
# file handle for acquiring and releasing the lock
my $fh;
my $lock_file_path = "/var/prtg/logs/prtg_horcm_";
my $hrcm_repl_hash = {};

# HORCM command paths
my $RAIDQRY = "/HORCM/usr/bin/raidqry";
my $PAIRDISPLAY = "/HORCM/usr/bin/pairdisplay";

main();
exit 0;

#========
sub main {

    get_input();

    if ($exe_opt_val =~ /monitor_process/) {
        $prtg_log_file =~ s/\.log$/_/;
        $prtg_log_file = $prtg_log_file . $exe_opt_val . ".log";
    }
    elsif ($exe_opt_val =~ /monitor_replica/) {
        $prtg_log_file =~ s/\.log$/_/;
        $prtg_log_file = $prtg_log_file . $exe_opt_val . $hid_to_monitor . ".log";
    }

    #print "log file path is $prtg_log_file\n";
    _logmsg("Start");

    if ($exe_opt_val =~ /monitor_process/) {
        check_running_process(0);
        print_json();
    }
    elsif ($exe_opt_val =~ /monitor_replica/) {
        check_horcm_repl();
        print_json();
    }
    else {
        _logmsg("No input option provided");
    }

    _logmsg("End");
}

sub check_horcm_journal {
}

sub check_horcm_repl {

    my $msg;
    if (acquire_horcm_lock() == 0) {
        log_n_exit("ERROR: Cannot acquire lock. Previous monitor process for [$hid_to_monitor] still executing. Exit");
    }

    if (check_horcm_process() == 0) {
        log_n_exit("ERROR: HORCM process for [$hid_to_monitor] is down. Exit");
    }

    my $cg_name;
    if (get_cg_for_inst($hid_to_monitor, \$cg_name) == 0) {
        log_n_exit("ERROR: raidqry exec failed for [$hid_to_monitor]. Exit");
    }

    _logmsg("Got cgname as [$cg_name]");

    my @paird_out;
    my $pos_to_chk;
    if (get_pairdisp_out($cg_name, $hid_to_monitor, \$pos_to_chk, \@paird_out) == 0) {
        log_n_exit("ERROR: pairdisplay exec failed for [$cg_name] [$hid_to_monitor]. Exit");
    }

    #_logmsg("Got good output for pairdisplay. Continue to check for replication lag [$pos_to_chk] and array [@paird_out]");
    _logmsg("Got good output for pairdisplay. Continue to check for replication lag");
    check_repl_status($pos_to_chk, @paird_out);

    # If position ($pos) is 8, means the instance is true copy
    # For true copy instances, check the journal usage.
    if ($pos_to_chk == 8) {
        check_journal_details($cg_name, $hid_to_monitor);
    }

    # Since done with execution, release the lock.
    # The only pending item is to print json, but that should
    # be quick.
    release_lock();
}

# ===================== # =====================
#    HORCM Journal related modules
# ===================== # =====================
sub check_journal_details {
    my ($cg_name, $hid_to_monitor) = @_;
    my @jnl_out;
    if (get_pairdisp_jnl($cg_name, $hid_to_monitor, \@jnl_out) == 0) {
        log_n_exit("ERROR: pairdisplay for journal failed for CG [$cg_name] hid [$hid_to_monitor]. Exit");
        # Do not fail. Just return.
        return;
    }

    check_jnl($cg_name, @jnl_out);;
}

sub check_jnl {
    my ($cg, @jnl_out) = @_;

    # Following are the different journal status:
    # SMPML - means the journal vol which does not have a pair or in
    #       the state of deleting
    #
    # PJNN/SJNN - journal vol in normal status
    #
    # P(S)JNS - journal vol suspended in normal status
    #         (created with -nocsus option)
    #
    # P(S)JSN - journal vol suspended in normal status
    #
    # P(S)JNF - journal vol is in full status
    #
    # P(S)JSF - journal vol is suspended in full status
    #
    # P(S)JSE - journal vol is suspended by an error (including link failures)
    #
    # P(S)JES - journal vol is suspended by an error (created with -nocsus option)

    # PRTG custom value lookup is :
    #
    #    <Range state="Ok" from="0" to="69">TC_Journal_Under70</Range>
    #    <Range state="Warning" from="70" to="79">TC_Journal_70_79</Range>
    #    <Range state="Error" from="80" to="100">TC_Journal_Above80</Range>
    #    <Range state="Error" from="-1" to="-1">TC_Journal_SMPL</Range>
    #    <Range state="Error" from="-2" to="-2">TC_Jnl_PJSN_Suspended</Range>
    #    <Range state="Error" from="-3" to="-3">TC_Jnl_PJNF_Full</Range>
    #    <Range state="Error" from="-4" to="-4">TC_Jnl_PJSF_Sus_Full</Range>
    #    <Range state="Error" from="-5" to="-5">TC_Jnl_PJSE_Sus_Error</Range>
    #    <Range state="Error" from="-6" to="-6">TC_Jnl_UnKnown</Range>

    my $prtg_value_lookup = "prtg.custom.horcm_truecopy_journal.status";

    foreach my $line (@jnl_out) {
        chomp($line);
        # skip the first line
        next if ($line =~ /^JID\s+MU\s+CTG\s+JNLS/);

        my $val;
        my @data = split (/\s+/, $line);
        _logmsg("check_jnl: line is [$line]");

        my $jnl_id = $cg . "_JID_$data[0]";
        if (exists $hrcm_repl_hash->{$jnl_id}) {
            _logmsg("check_jnl: ERROR: got a journal with same ID [$line]. Skip");
            next;
        }

        my $status_pos = 3;

        if ($data[$status_pos] =~ /SJNN|PJNN/) {
            $val = $data[$status_pos+2];
        }
        elsif ($data[$status_pos] =~ /PJSN|SJSN/) {
            $val = -2;
        }
        elsif ($data[$status_pos] =~ /PJNF|SJNF/) {
            $val = -3;
        }
        elsif ($data[$status_pos] =~ /PJSF|SJSF/) {
            $val = -4;
        }
        elsif ($data[$status_pos] =~ /PJSE|SJSE/) {
            $val = -5;
        }
        elsif ($line =~ / SMPL /) {
            $val = -1;
        }
        else {
            $val = -6;
        }

        _logmsg("check_jnl: Setting value [$val] for Jnl ID [$jnl_id]");
        $hrcm_repl_hash->{$jnl_id}->{VALUE} = $val;
        $hrcm_repl_hash->{$jnl_id}->{LOOKUP} = $prtg_value_lookup;
    }
}

sub get_pairdisp_jnl {
    my ($cg, $hid, $out_arr) = @_;

    # Collect the journal details only for local
    # If the remote site is down, the command without local
    # '-l' option will hang

    my $cmd = "$PAIRDISPLAY -g $cg -I$hid -fcx -CLI -v jnl -l";

    _logmsg("get_pairdisp_jnl: Executing command [$cmd]");
    @$out_arr = `$cmd`;
    if ($? != 0) {
        _logmsg("get_pairdisp_jnl: ERROR: command [$cmd] failed. Return");
        return 0;
    }
    # Command execution was fine, so return whatever was
    # obtained
    return 1;
}

# ===================== # =====================
#    HORCM Replication related modules
# ===================== # =====================
sub check_repl_status {
    my ($pos, @out) = @_;

    # If position ($pos) is 8, means the instance is true copy
    # If it is 9, means it is a shadow image instance

    # For true copy instance, the % reported is as follows:
    #  - Since the transfer is ‘ASYNC’, the reported percentage for each LUN is the percentage of data to transfer
    #  - This is the value even when the LUNs are in PAIR state
    #  - During COPY status, the value reported as % is the percentage complete (it’s the opposite of the PAIR state)
    #  - Based on my understanding (couldn’t find proper documentation), the amount of change at primary site
    #       that is yet to be replicated to secondary in terms of percentage of the LUN size
    #
    #  - During normal bussiness hours, the value observed is 0 or 1. Meaning the LUNs are mostly in sync
    #  - The lower the value the lesser the replication lag
    #
    # TrueCopy : Below is the range/values set for in the PRTG custom lookup value file
    # (dated 30th Aug)
    #    <Range state="Ok" from="0" to="29">TC_Repl_Under30</Range>
    #    <Range state="Warning" from="30" to="40">TC_Repl_30_40</Range>
    #    <Range state="Error" from="41" to="100">TC_Repl_Above40</Range>
    #    <Range state="Error" from="-1" to="-1">TC_Repl_SMPL</Range>
    #    <Range state="Error" from="-2" to="-2">TC_Repl_COPY</Range>
    #    <Range state="Error" from="-3" to="-3">TC_Repl_PSUS</Range>
    #    <Range state="Error" from="-4" to="-4">TC_Repl_PSUE</Range>
    #    <Range state="Error" from="-5" to="-5">TC_Repl_SSWS</Range>
    #    <Range state="Error" from="-6" to="-6">TC_Repl_UnKnown</Range>

    # For shadow image replication (Mitcham to Mitcham for fire-drill)
    #  - The percentage reported is the percent complete
    #  - The value usually observed is 99/100%
    #  - The larger the value the better the replication
    #
    # ShadowImage : Below is the range/values set for in the PRTG custom lookup value file
    # (dated 30th Aug)
    #    <Range state="Ok" from="70" to="100">TC_Repl_70_100</Range>
    #    <Range state="Warning" from="60" to="69">TC_Repl_60_69</Range>
    #    <Range state="Error" from="0" to="59">TC_Repl_Below60</Range>
    #    <Range state="Error" from="-1" to="-1">TC_Repl_SMPL</Range>
    #    <Range state="Error" from="-2" to="-2">TC_Repl_COPY</Range>
    #    <Range state="Error" from="-3" to="-3">TC_Repl_PSUS</Range>
    #    <Range state="Error" from="-4" to="-4">TC_Repl_PSUE</Range>
    #    <Range state="Error" from="-5" to="-5">TC_Repl_SSWS</Range>
    #    <Range state="Error" from="-6" to="-6">TC_Repl_UnKnown</Range>


    my $prtg_value_lookup = "prtg.custom.horcm_truecopy_repl.status";
    my $pos_to_add_for_repl_percent = 3;
    if ($pos == 9) {
        $prtg_value_lookup = "prtg.custom.horcm_shadowimage_repl.status";
        $pos_to_add_for_repl_percent = 2;
    }

    foreach my $line (@out) {
        chomp($line);
        # skip the first line
        next if ($line =~ /^Group\s+PairVol\s+L\/R\s+Port/);

        my $val;
        my @data = split (/\s+/, $line);
        _logmsg("check_repl_status: line is [$line]");

        # the Pair volume name in each CG has to be unique
        # Note: there can be two CGs in an instances and volume name can
        # be same. But shouldn't be a concern for us.
        if (exists $hrcm_repl_hash->{$data[1]}) {
            _logmsg("check_repl_status: ERROR: got a pair volume with same name [$line]. Skip");
            next;
        }

        if ($data[$pos] =~ /S-VOL|P-VOL/) {
            if ($data[$pos+1] eq "PAIR") {
                $val = $data[$pos + $pos_to_add_for_repl_percent];
            }
            elsif ($data[$pos+1] eq "COPY") {
                $val = -2;
            }
            elsif ($data[$pos+1] =~ /PSUS|SSUS/) {
                $val = -3;
            }
            elsif ($data[$pos+1] eq "PSUE") {
                $val = -4;
            }
            elsif ($data[$pos+1] eq "SSWS") {
                $val = -5;
            }
            else {
                $val = -6;
            }
        }
        elsif ($line =~ / SMPL /) {
            $val = -1;
        }
        $hrcm_repl_hash->{$data[1]}->{VALUE} = $val;
        $hrcm_repl_hash->{$data[1]}->{LOOKUP} = $prtg_value_lookup;
    }
}

# The naming format of the CGs is such that it
# can be used to know which are true copy instances
# (the ones getting replicated from customer to GS) as
# compared to the shadow image instances.
# the shadow image instances have CG names starting
# with "SI_"
# But lets not depend on the naming format, so as if
# someone creates a CG with a different name, the code
# should not fail.

# The logic to get the replication details for a CG is:
# First try to execute the command as a true copy (-I<instance>)
# if this fails (the sate is SMPL), then change the command to
# check if it works for shadow image (-IM<instance>)

# Sample output for true copy instance:
# # /HORCM/usr/bin/pairdisplay -g CG_MAN02 -I121 -fcx -CLI
# Group           PairVol     L/R Port#   TID  LU Seq#    LDEV# P/S Status Fence    % P-LDEV# M
# CG_MAN02        CG_MAN02_01 L   CL5-E-3  0   26 413541   6a6 S-VOL PAIR ASYNC      0   5a6 -
# CG_MAN02        CG_MAN02_01 R   CL1-A-3  0    2 410673   5a6 P-VOL PAIR ASYNC      1   6a6 -
# ...
# 0               1           2   3        4    5 6        7   8     9    10         11  12  13

# Sample output for shadow image instance:
# [root@c1064-rephorcm ~]# /HORCM/usr/bin/pairdisplay -g SI_CG_MAN02 -IM321 -fcx -CLI
# Group   PairVol L/R   Port# TID  LU-M   Seq# LDEV# P/S Status    %  P-LDEV# M
# SI_CG_MAN02     SI_CG_MAN02_01 L   CL5-E-3  0   26 1  413541   6a6 P-VOL PAIR   100     2a6 -
# SI_CG_MAN02     SI_CG_MAN02_01 R   CL5-E-3  0  262 0  413541   2a6 S-VOL PAIR   100     6a6 -
# ...
# 0               1              2   3        4    5 6  7        8   9     10     11      12  13

# NOTE: It is best to execute the command with local option "-l"
# as without the local option, there is a possibility for
# the command to hang if the remote site is down.
sub get_pairdisp_out {
    my ($cg_name, $hid, $pos_to_ret, $paird_out) = @_;

    my $inst = "-I$hid"; # first check for true copy instance.
    my $pos = 8; # position to check for true copy instance
    my $try = 0;
    for(my $i = 0; $i < 2; $i++) {
        $try++;
        my $cmd = "$PAIRDISPLAY -g $cg_name $inst -fcx -CLI -l";
        _logmsg("get_pairdisp_out: Executing command [$cmd]");
        @$paird_out = `$cmd`;
        if ($? != 0) {
            if ($try == 1) {
                _logmsg("get_pairdisp_out: pairdisplay command execution [$cmd] failed. Try for shadow image");
                next;
            }
            _logmsg("get_pairdisp_out: ERROR: command [$cmd] failed. Return");
            return 0;
        }

        _logmsg("get_pairdisp_out: Got pairdisplay output. Checking if this is good");
        if (is_pairdisplay_output_good($pos, @$paird_out) == 1) {
            # Got a good output that has S-VOL or P-VOL.
            # return as success
            $$pos_to_ret = $pos;
            return 1;
        }

        # Did not get a good output. Check if there is another shadow
        # image execution.
        if ($try == 1) {
            $inst = "-IM$hid";
            $pos = 9;  # position to check for shadow image
            _logmsg("get_pairdisp_out: first try failed. Checking again with inst as [$inst]");
            next;
        }

        # If reached here, means both tries executed and failed to get a good output
        # return failure.
        return 0;
    }
}

sub is_pairdisplay_output_good {
    my ($pos_to_chk, @out) = @_;

    foreach my $line (@out) {
        chomp($line);
        # skip the first line
        next if ($line =~ /^Group\s+PairVol\s+L\/R\s+Port/);
        my @data = split (/\s+/, $line);
        _logmsg("is_pairdisplay_output_good: line is [$line]");

        # It is sufficient to find just one volume which has
        # S-VOL or P-VOL set to make sure the command execution
        # is correct for the instance.
        return 1 if ($data[$pos_to_chk] =~ /S-VOL|P-VOL/);
    }
    # Could not find any S-VOL or P-VOL in the output
    # return as this is not a good output
    return 0;
}


sub get_cg_for_inst {
    my ($hinst, $cg_name) = @_;
    my $cmd = "$RAIDQRY -g -I$hinst";
    _logmsg("get_cg_for_inst: Executing command [$cmd]");
    my @rout = `$cmd`;
    if ($? != 0) {
        _logmsg("ERROR: command [$cmd] failed");
        return 0;
    }

    my @cg_details;
    foreach my $line (@rout) {
        chomp($line);
        #skip the first line
        next if ($line =~ m/^GNo\s+Group\s+RAID_type/);
        _logmsg("get_cg_for_inst: raidqry output is - [$line]");
        @cg_details = split(/\s+/, $line);
        last;
    }
    return 0 if (@cg_details < 5);
    $$cg_name = $cg_details[2];
    _logmsg("get_cg_for_inst: Got cg name [$$cg_name] for instance [$hinst]");
    return 1;
}


sub check_horcm_process {
    check_running_process(1);
    if (!exists $hrcm_proc_hash->{$hid_to_monitor}) {
        return 0;
    }
    _logmsg("check_horcm_process: HORCM process horcmd_ [$hid_to_monitor] is online");
    return 1;
}

sub acquire_horcm_lock {
    my $msg;
    my $lock_file = $lock_file_path . $hid_to_monitor . ".lck";
    if (!open ($fh, '>', $lock_file)) {
        log_n_exit("ERROR: Cannot open file path [$lock_file] for locking. Exit");
    }
    _logmsg("acquire_horcm_lock: Trying to acquire lock");
    if (!flock($fh, LOCK_EX|LOCK_NB)) {
        _logmsg("ERROR: Cannot acquire lock for [$hid_to_monitor]");
        close ($fh);
        return 0;
    }
    _logmsg("acquire_horcm_lock: Got the lock");
    return 1;
}

sub release_lock {
    flock($fh, LOCK_UN);
    close($fh);
    _logmsg("release_lock: Done with releasing the lock.");
}

sub log_n_exit {
    my ($msg) = @_;
    _logmsg($msg);
    print $msg . "\n";
    exit 1;
}

# ===================== # =====================
#    HORCM Processes Status related modules
# ===================== # =====================

# Module for option 'monitor_process'
# Executes the ps command to find out the running
# horcmd process and creates a hash with the PID as the
# key. Later this hash is used to check which all input
# provided horcm IDs are running
#
sub check_running_process {
    my ($quick_exec) = @_;
    my $cmd = "$PS ax \| $GREP horcmd_ \| $GREP -v grep";
    #print "cmd is [$cmd]\n";
    my @exec_out = `$cmd`;
    my @temp;
    foreach my $out (@exec_out) {
        chomp($out);
        my $pid = 0;
        if ($out =~ /horcmd_0(\d+)/) {
            $pid = $1;
            push @temp, $pid;
        } else {
            _logmsg("Skipping out [$out]");
            next;
        }
        _logmsg("For out [$out] got pid as [$pid]");
        $hrcm_proc_hash->{$pid} = 1;
    }

    if ($quick_exec == 0) {
        # The below sorting code is for logging purpose only
        # It will be easier to match a sorted list.
        my @sorted_pid_list = sort {$a <=> $b} @temp;
        my $process_cnt = @sorted_pid_list;
        my $msg = "Total processes running [$process_cnt] and all processes [@sorted_pid_list]";
        _logmsg($msg);
        #print $msg . "\n";
    }
}


# Module that prints the final json as needed by PRTG
# This can be enhanced to take as input the value-lookup
# and also the option for which the execution is done
#
sub print_json {
    my $h = {};

    my @r;

    if ($exe_opt_val =~ /monitor_process/) {
        foreach my $p (@hrcm_list) {
           #print "Input HORCM PID to check: $p\n";
           my $t = {};
           $t->{Channel} = "Process horcmd_0 $p";
           my $val = 0;
           $val = 1 if (exists $hrcm_proc_hash->{$p});
           $t->{Value} = $val;
           $t->{ValueLookup} = "prtg.custom.horcmprocess.status";

           push @r, $t;
        }
    }
    elsif ($exe_opt_val =~ /monitor_replica/) {
        while (my ($vol, $h) = each %{$hrcm_repl_hash}) {
            my $t = {};
            $t->{Channel} = $vol;
            $t->{Value} = $h->{VALUE};
            $t->{ValueLookup} = $h->{LOOKUP};
            push @r, $t;
        }
    }

    $h->{prtg} = {};
    $h->{prtg}->{result} = \@r;

    my $json = encode_json $h;
    print $json;
    _logmsg("Done with print_json");
}

# Module to look at the input parameters.
# The input option '-opt' specifies the purpose of the
# execution. Eg. if the execution is for monitoring the
# horcm process or for monitoring the replication lag
#
# Based on the purpose of execution, fetch the remaining
# set of input parameters.
sub get_input {

    my $nxt_pid = 0;

    my $exe_opt = 1;

    foreach my $p (@ARGV) {
        #_logmsg("Provided input para is [$p]");

        if (($exe_opt == 1) && (($p eq "-opt") || $exe_opt_val eq "-opt")) {
            _logmsg("Provided input para for options is [$p]");
            $exe_opt_val = $p;
            next if ($p eq "-opt");

            $exe_opt = 0; # so as the execution does not enter this check after first two parameters

            if ($exe_opt_val !~ /monitor_process|monitor_replica/) {
                my $msg = "ERROR: Value set for -opt [$exe_opt_val] is not supported";
                _logmsg($msg);
                print $msg . "\n";
                exit 1;
            }
        }

        if ($exe_opt_val =~ /monitor_process/) {

            # If the input is as below:
            # prtg_horcm_mon.sh -opt monitor_process -hid 201 -hid 202 -hid 306 -hid 406 -hid 121

            if ($nxt_pid == 1) {
                if ($p eq "\-hid") {
                    my $msg = "Incorrect input parameter. Two -hid's provided together";
                    _logmsg($msg);
                    print $msg . "\n";
                    exit 1;
                }
                if ($p =~ /\d+/) {
                    push @hrcm_list, $p;
                } else {
                    my $msg = "Incorrect input parameter. HORCM process ID excepted";
                    _logmsg($msg);
                    print $msg . "\n";
                    exit 1;
                }
                $nxt_pid = 0;
                next;
            }
            if ($p eq "-hid") {
                $nxt_pid = 1;
                next;
            }
        }
        elsif ($exe_opt_val =~ /monitor_replica/) {

            # If the input is as below:
            # prtg_horcm_mon.pl -opt monitor_replica -hid 201

            if ($nxt_pid == 1) {
                if ($p eq "\-hid") {
                    my $msg = "ERROR: Incorrect input parameter. Two -hid's provided together";
                    _logmsg($msg);
                    print $msg . "\n";
                    exit 1;
                }
                if ($p =~ /\d+/) {
                    $hid_to_monitor = $p;

                    # Even if there is any other input, skip it
                    last;
                } else {
                    my $msg = "ERROR: Incorrect input parameter. HORCM process ID excepted";
                    _logmsg($msg);
                    print $msg . "\n";
                    exit 1;
                }
                $nxt_pid = 0;
                next;
            }
            if ($p eq "-hid") {
                $nxt_pid = 1;
                next;
            }
        }
    }
}

# Log the message in a log file using echo.
# If the message is for 'start' or 'end', it will
# be logged along with date and time. This will help
# know the start and end of the execution.
sub _logmsg
{
    my $msg = shift;
    $msg = $$ . " : $msg";

    if ($msg =~ /start|end/i) {
        my $dt = `/bin/date`;
        my $msg = "======================\n    $msg : $dt\n======================";
        `/bin/echo \"$msg\" &>> $prtg_log_file`;
        #`/bin/date &>> $prtg_log_file`;
        return;
    }
    `/bin/echo \"$msg\" &>> $prtg_log_file`;
}

