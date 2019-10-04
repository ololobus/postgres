#
# Test that running pg_rewind with the source and target clusters
# on the same timeline runs successfully.
#
use strict;
use warnings;
use TestLib;
use Test::More tests => 6;

use FindBin;
use lib $FindBin::RealBin;

use RewindTest;

sub run_test
{
	my $test_mode = shift;

	RewindTest::setup_cluster($test_mode, ['-g']);
	RewindTest::start_master();
	RewindTest::create_standby($test_mode);

	RewindTest::promote_standby();

	RewindTest::run_pg_rewind($test_mode);

	RewindTest::clean_rewind_test();
	return;
}

# Run the test in both modes.
run_test('local');
run_test('remote');

exit(0);
