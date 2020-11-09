#
# Check that pg_prewarm can dump blocks from shared buffers
# to PGDATA/autoprewarm.blocks.
#

use strict;
use Test::More;
use TestLib;
use Time::HiRes qw(usleep);
use warnings;

use PostgresNode;

plan tests => 3;

my $node = get_new_node("node");
$node->init;
$node->append_conf(
    'postgresql.conf', qq(
shared_preload_libraries = 'pg_prewarm'
pg_prewarm.autoprewarm = 'on'
pg_prewarm.autoprewarm_interval = 1
));
$node->start;

my $blocks_path = $node->data_dir . '/autoprewarm.blocks';

# Check that we can dump blocks on timeout.
# Wait up to 180s for pg_prewarm to dump blocks.
foreach my $i (0 .. 1800)
{
	last if -e $blocks_path;
	usleep(100_000);
}
ok(-e $blocks_path, 'file autoprewarm.blocks should be present in the PGDATA');

# Check that we can dump blocks on shutdown.
$node->stop;
$node->append_conf(
    'postgresql.conf', qq(
pg_prewarm.autoprewarm_interval = 0
));

# Remove autoprewarm.blocks
unlink($blocks_path) || die "$blocks_path: $!";
ok(!-e $blocks_path, 'sanity check, dump on timeout is turned off');

$node->start;
$node->stop;

ok(-e $blocks_path, 'file autoprewarm.blocks should be present in the PGDATA after clean shutdown');
