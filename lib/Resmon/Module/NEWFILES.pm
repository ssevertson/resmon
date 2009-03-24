package Resmon::Module::NEWFILES;
use Resmon::ExtComm qw/cache_command/;
use vars qw/@ISA/;
use File::Find;
@ISA = qw/Resmon::Module/;

# Checks to ensure that files exist in a directory that are younger than a
#   certain time
# Parameters:
#   minutes : how old can the newest file be before we alarm
#   filecount : how many new files do we require (default 1)
# Example:
#
# NEWFILES {
#   /test/dir : minutes => 5
#   /other/dir : minutes => 60, filecount => 2
# }

my $minutes;
my $newcount = 0;

sub handler {
    my $arg = shift;
    my $dir = $arg->{'object'};
    $minutes = $arg->{'minutes'};
    my $filecount = $arg->{'filecount'} || 1;
    $newcount = 0;

    # Then look for new files
    find(\&wanted, $dir);
    if ($newcount >= $filecount) {
        return "OK", "$newcount files";
    } else {
        return "BAD", "$newcount files";
    }
}

sub wanted {
    my @fstat = stat($_);
    my $lastmodified = time() - $fstat[9];
    -f $_ && $lastmodified < ($minutes * 60) && $newcount++;
}

1;