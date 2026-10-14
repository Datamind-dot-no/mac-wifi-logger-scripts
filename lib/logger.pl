#!/usr/bin/perl
use strict;
use warnings;
use Time::HiRes qw(time sleep);
use POSIX qw(strftime WNOHANG);
use Time::Local qw(timegm);
use Sys::Hostname qw(hostname);
use JSON::PP qw(decode_json);
use Fcntl qw(:flock);
use IO::Handle;

my @header = qw(timestamp_utc machine_id stream gateway status icmp_seq rtt_ms association ssid bssid rssi_dbm noise_dbm channel tx_rate_mbps source message);
my $mode = shift @ARGV // '';
die "Usage: logger.pl ping|state|event|merge [CSV files for merge]\n"
    unless $mode =~ /^(ping|state|event|merge)$/;
my ($child, $output, $lock);
my $stop = 0;
sub system_diagnostic {
    my ($message) = @_;
    return unless $ENV{WIFI_LAUNCHD} && -x '/usr/bin/logger';
    local $SIG{__WARN__};
    system('/usr/bin/logger', '-t', 'mac-wifi-troubleshooter', $message);
}
$SIG{__WARN__} = sub { system_diagnostic($_[0]); print STDERR $_[0]; };
$SIG{__DIE__} = sub { system_diagnostic($_[0]) unless $^S; };
$SIG{INT} = $SIG{TERM} = sub {
    $stop = 1;
    kill 'TERM', $child if $child;
};
END {
    if ($child) {
        kill 'TERM', $child;
        waitpid($child, 0);
    }
}

sub stamp {
    my $t = shift // time;
    my $seconds = int($t);
    return strftime('%Y-%m-%dT%H:%M:%S', gmtime($seconds))
        . sprintf('.%06dZ', int(($t - $seconds) * 1_000_000));
}

sub csv {
    return join(',', map {
        my $v = defined($_) ? "$_" : '';
        $v =~ s/"/""/g;
        qq{"$v"};
    } @_) . "\n";
}

# Our writers escape newlines so each physical line is one CSV record.
sub parse_csv {
    my ($line) = @_;
    $line =~ s/\r?\n$//;
    my @values;
    while ($line =~ s/^"((?:[^"]|"")*)"(?=,|$)//) {
        my $value = $1;
        $value =~ s/""/"/g;
        push @values, $value;
        last unless $line =~ s/^,//;
        die "Malformed CSV record\n" unless length $line;
    }
    die "Malformed CSV record\n" if length $line;
    return @values;
}

if ($mode eq 'merge') {
    die "Usage: merge-logs.sh file.csv [file.csv ...] > merged.csv\n" unless @ARGV;
    # External sort bounds memory for multi-day captures. Quoted ISO timestamps
    # have identical widths, so their lexical order is chronological.
    $ENV{LC_ALL} = 'C';
    my $sort_pid = open(my $sort, '|-', '/usr/bin/sort', '-s', '-t', ',', '-k1,1', '-k2,2')
        or die "Cannot start sort: $!\n";
    $child = $sort_pid;
    print csv(@header);
    STDOUT->flush();
    for my $path (@ARGV) {
        last if $stop;
        open my $in, '<', $path or die "Cannot read $path: $!\n";
        my $first = <$in>;
        die "Wrong CSV schema in $path\n" unless defined($first) && $first eq csv(@header);
        while (my $line = <$in>) {
            last if $stop;
            my @row = parse_csv($line);
            die "Invalid row in $path\n" unless @row == @header
                && $row[0] =~ /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/;
            print {$sort} $line or die "Cannot write to sort: $!\n";
        }
        close $in;
    }
    my $ok = close $sort;
    $child = undef;
    die "sort failed\n" unless $ok || $stop;
    exit 0;
}

die "Collectors require macOS\n" unless $^O eq 'darwin';
die "Unexpected arguments\n" if @ARGV;
for my $name (qw(PING_INTERVAL SAMPLE_INTERVAL)) {
    die "$name must be a positive number\n"
        unless ($ENV{$name} // '') =~ /^\d+(?:\.\d+)?$/ && $ENV{$name} > 0;
}
for my $name (qw(RETENTION_DAYS MAX_LOG_BYTES)) {
    die "$name must be a positive integer\n"
        unless ($ENV{$name} // '') =~ /^[1-9]\d*$/;
}
my $dir = $ENV{OUTPUT_DIR} // die "OUTPUT_DIR is required\n";
die "OUTPUT_DIR must be an absolute path\n" unless $dir =~ m{^/};
umask 0077;
require File::Path;
File::Path::make_path($dir);
open $lock, '>>', "$dir/$mode.lock" or die "Cannot open lock: $!\n";
flock($lock, LOCK_EX | LOCK_NB) or die "A $mode collector is already running in $dir\n";
my $host = $ENV{MACHINE_ID} || hostname();
my ($size, $day, $last_prune, $serial) = (0, '', 0, 0);
my $path = "$dir/$mode.csv";

sub prune {
    return if time - $last_prune < 60;
    $last_prune = time;
    opendir my $dh, $dir or die "Cannot list $dir: $!\n";
    for my $name (readdir $dh) {
        next unless $name =~ /^\Q$mode\E-\d{8}T\d{12}Z-\d+-\d+\.csv$/;
        my $file = "$dir/$name";
        next unless -f $file && !-l $file;
        unlink($file) or die "Cannot remove $file: $!\n"
            if (stat($file))[9] < time - $ENV{RETENTION_DAYS} * 86400;
    }
    closedir $dh;
}

sub emit {
    my (%record) = @_;
    $record{timestamp_utc} //= stamp();
    $record{machine_id} = $host;
    $record{stream} = $mode;
    for (values %record) {
        s/\r/\\r/g;
        s/\n/\\n/g;
    }
    my $line = csv(map { $record{$_} // '' } @header);
    my $today = substr(stamp(), 0, 10);
    if (!$output) {
        die "Refusing symlink $path\n" if -l $path;
        if (-s $path) {
            open my $in, '<', $path or die "Cannot read $path: $!\n";
            die "Wrong CSV schema in $path\n" unless (<$in> // '') eq csv(@header);
            close $in;
            $day = strftime('%Y-%m-%d', gmtime((stat($path))[9]));
        }
        open $output, '>>', $path or die "Cannot write $path: $!\n";
        $output->autoflush(1);
        $size = -s $path;
        if (!$size) { print {$output} csv(@header) or die "Write failed: $!\n"; $size = -s $path; $day = $today; }
    }
    if ($size + length($line) > $ENV{MAX_LOG_BYTES} || $day ne $today) {
        close $output or die "Close failed: $!\n";
        my $suffix = stamp();
        $suffix =~ s/[-:.]//g;
        rename($path, "$dir/$mode-$suffix-$$-" . ++$serial . '.csv')
            or die "Rotation failed: $!\n";
        open $output, '>', $path or die "Cannot write $path: $!\n";
        $output->autoflush(1);
        print {$output} csv(@header) or die "Write failed: $!\n";
        $size = length(csv(@header));
        $day = $today;
    }
    print {$output} $line or die "Write failed: $!\n";
    $size += length($line);
    prune();
}

sub spawn {
    my @cmd = @_;
    die "Required binary unavailable: $cmd[0]\n" unless -x $cmd[0];
    my $pid = open(my $fh, '-|');
    die "Cannot fork: $!\n" unless defined $pid;
    if (!$pid) {
        open STDIN, '<', '/dev/null' or die "Cannot open /dev/null: $!\n";
        open STDERR, '>&', STDOUT or die "Cannot capture ping errors: $!\n"
            if $mode eq 'ping';
        exec @cmd;
        die "Cannot execute $cmd[0]: $!\n";
    }
    $child = $pid;
    return $fh;
}

sub finish {
    my ($fh) = @_;
    close $fh;
    my $status = $?;
    $child = undef;
    return $status;
}

sub capture {
    my @cmd = @_;
    my $fh = spawn(@cmd);
    my $text = '';
    my $timed_out;
    {
        local $SIG{ALRM} = sub { $timed_out = 1; kill 'KILL', $child if $child; };
        alarm 20;
        while (my $line = <$fh>) { $text .= $line; }
        alarm 0;
    }
    my $status = finish($fh);
    return ($text, $status || $timed_out);
}

sub state_fields {
    my ($text, $source) = @_;
    my %r = (source => $source, association => 'unknown');
    if ($source eq 'wdutil') {
        # AWDL/other sections repeat Wi-Fi keys but describe different radios.
        my @wifi;
        my $in_wifi = 0;
        for my $line (split /\n/, $text) {
            if ($line =~ /^WIFI\s*$/) { $in_wifi = 1; next; }
            last if $in_wifi && $line =~ /^[A-Z][A-Z0-9 _-]*$/;
            push @wifi, $line if $in_wifi;
        }
        $text = join("\n", @wifi);
    } elsif ($text =~ /Current Network Information:\s*\n(.*)/s) {
        $text = "Current Network Information:\n$1";
        $text =~ s/\n\s*Other Local Wi-Fi Networks:.*//s;
    }
    my %keys = ('SSID' => 'ssid', 'BSSID' => 'bssid', 'RSSI' => 'rssi_dbm',
        'Noise' => 'noise_dbm', 'Channel' => 'channel', 'Tx Rate' => 'tx_rate_mbps',
        'Transmit Rate' => 'tx_rate_mbps');
    for my $line (split /\n/, $text) {
        if ($line =~ /^\s*([^:]+?)\s*:\s*(.*?)\s*$/) {
            my ($key, $value) = ($1, $2);
            next unless exists $keys{$key};
            next if $value =~ /^(?:<redacted>|<private>|N\/A|none|unknown|)$/i;
            $value = $1 if $keys{$key} =~ /^(?:rssi_dbm|noise_dbm|tx_rate_mbps)$/
                && $value =~ /^(-?\d+(?:\.\d+)?)/;
            $r{$keys{$key}} = $value;
        }
    }
    if ($source eq 'system_profiler') {
        # Only inspect the current network, not the scan of other nearby APs.
        if ($text =~ /Current Network Information:\s*\n\s*([^\n]+):\s*\n/) {
            $r{ssid} = $1;
            $r{ssid} =~ s/^\s+|\s+$//g;
            if ($r{ssid} =~ /^(?:<redacted>|<private>|none|unknown)$/i) {
                delete $r{ssid};
            } else { $r{association} = 'associated'; }
        }
        if ($text =~ /Signal \/ Noise:\s*(-?\d+)\s*dBm\s*\/\s*(-?\d+)/) {
            @r{qw(rssi_dbm noise_dbm)} = ($1, $2);
        }
    }
    $r{association} = 'associated' if $r{ssid} || $r{bssid};
    $r{association} = 'disconnected' if $text =~ /(?:Not Associated|Status:\s*Off|State\s*:\s*disconnected|Op Mode\s*:\s*None|Power\s*:\s*Off)/i;
    $r{message} = 'Association identifiers unavailable; redacted data is not proof of disconnection'
        if $r{association} eq 'unknown';
    return %r;
}

if ($mode eq 'ping') {
    my ($route, $error) = capture('/sbin/route', '-n', 'get', 'default');
    die "Cannot discover default gateway; check network connection\n" if $error;
    my ($gateway) = $route =~ /^\s*gateway:\s*(\d+\.\d+\.\d+\.\d+)\s*$/m;
    die "No IPv4 default gateway found\n" unless $gateway;
    my $fh = spawn('/sbin/ping', '-n', '-i', $ENV{PING_INTERVAL}, $gateway);
    while (!$stop && defined(my $line = <$fh>)) {
        chomp $line;
        my %r = (gateway => $gateway, source => 'ping', message => $line, status => 'info');
        $r{icmp_seq} = $1 if $line =~ /icmp_seq[= ](\d+)/;
        if ($line =~ /time([=<])([\d.]+)\s*ms/) {
            $r{status} = 'reply';
            $r{rtt_ms} = $2;
        } elsif ($line =~ /(?:timeout|100(?:\.0)?% packet loss)/i) { $r{status} = 'timeout'; }
        elsif ($line =~ /(?:unreachable|no route|sendto|error)/i) { $r{status} = 'error'; }
        emit(%r);
    }
    my $status = finish($fh);
    die "ping exited ($status); check gateway and permissions\n" unless $stop;
} elsif ($mode eq 'state') {
    my $wdutil = -x '/usr/bin/wdutil' && $> == 0;
    my $profiler = -x '/usr/sbin/system_profiler';
    die "Need sudo for wdutil or an available system_profiler\n" unless $wdutil || $profiler;
    warn "wdutil unavailable or not root; using slower system_profiler fallback\n" unless $wdutil;
    while (!$stop) {
        my $start = time;
        my %r;
        if ($wdutil) {
            my ($text, $err) = capture('/usr/bin/wdutil', 'info');
            %r = state_fields($text, 'wdutil') unless $err;
            if ($err) { warn "wdutil failed; falling back to system_profiler\n"; $wdutil = 0; }
        }
        if ((!%r || ($r{association} eq 'unknown' && !exists $r{rssi_dbm}))
                && $profiler && !$stop) {
            my ($text, $err) = capture('/usr/sbin/system_profiler', 'SPAirPortDataType', '-detailLevel', 'full');
            if (!$err) {
                # Discard nearby network scan entries before parsing.
                $text =~ s/\n\s*Other Local Wi-Fi Networks:.*//s;
                my %fallback = state_fields($text, 'system_profiler');
                %r = %fallback if !%r || $fallback{association} ne 'unknown';
            } elsif (!%r) { die "Wi-Fi state sources failed or timed out\n" unless $stop; }
        }
        last if $stop;
        die "Wi-Fi state sources failed; no fallback available\n" unless %r;
        emit(%r, timestamp_utc => stamp($start));
        my $remaining = $ENV{SAMPLE_INTERVAL} - (time - $start);
        sleep($remaining) if $remaining > 0 && !$stop;
    }
} else {
    my $fh = spawn('/usr/bin/log', 'stream', '--style', 'ndjson', '--level', 'debug',
        '--predicate', 'subsystem == "com.apple.wifi"');
    while (!$stop && defined(my $line = <$fh>)) {
        chomp $line;
        next unless length $line;
        my $event = eval { decode_json($line) };
        if (!$event || ref($event) ne 'HASH') {
            emit(source => 'log', status => 'info', message => $line);
            next;
        }
        my $ts = $event->{timestamp} // '';
        my $utc;
        if ($ts =~ /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d):(\d\d)(?:\.(\d+))?(Z|[+-]\d\d:?\d\d)$/) {
            my ($y,$m,$d,$h,$min,$s,$fraction,$zone) = ($1,$2,$3,$4,$5,$6,$7 // '0',$8);
            my $epoch = timegm($s,$min,$h,$d,$m-1,$y);
            if ($zone ne 'Z') {
                $zone =~ /^([+-])(\d\d):?(\d\d)$/;
                $epoch -= ($1 eq '+' ? 1 : -1) * ($2 * 3600 + $3 * 60);
            }
            $utc = strftime('%Y-%m-%dT%H:%M:%S', gmtime($epoch))
                . '.' . substr($fraction . '000000', 0, 6) . 'Z';
        }
        emit(timestamp_utc => $utc // stamp(), source => 'log',
            status => $utc ? 'event' : 'timestamp_unparsed',
            message => $utc ? ($event->{eventMessage} // $line) : $line);
    }
    my $status = finish($fh);
    die "log stream exited ($status); check permissions (try sudo)\n" unless $stop;
}
close $output or die "Close failed: $!\n" if $output;
exit 0;
