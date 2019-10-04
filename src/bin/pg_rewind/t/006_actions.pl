#
# Test incompatible options and pg_rewind internal sanity checks.
#
use strict;
use warnings;
use TestLib;
use Test::More tests => 3;

use FindBin;
use lib $FindBin::RealBin;

use RewindTest;

RewindTest::setup_cluster('local', ['-g']);
RewindTest::start_master();
RewindTest::create_standby('local');

my $master_pgdata   = $node_master->data_dir;
my $standby_pgdata  = $node_standby->data_dir;

RewindTest::promote_standby();

# Check that pg_rewind errors out if target server
# wasn't shutdown.
command_fails(
    [
        'pg_rewind', "--debug",
        "--source-pgdata=$standby_pgdata",
        "--target-pgdata=$master_pgdata",
        "--no-ensure-shutdown"
    ],
    'pg_rewind local without target shutdown');

$node_master->stop;

# Check that pg_rewind errors out if source server
# wasn't shutdown.
command_fails(
    [
        'pg_rewind', "--debug",
        "--source-pgdata=$standby_pgdata",
        "--target-pgdata=$master_pgdata",
        "--no-ensure-shutdown"
    ],
    'pg_rewind local without source shutdown');

$node_standby->stop;

# Check that incompatible options error out.
command_fails(
    [
        'pg_rewind', "--debug",
        "--source-pgdata=$standby_pgdata",
        "--target-pgdata=$master_pgdata",
        "--write-recovery-conf",
        "--no-ensure-shutdown"
    ],
    'pg_rewind local with --write-recovery-conf');

RewindTest::clean_rewind_test();

exit(0);
