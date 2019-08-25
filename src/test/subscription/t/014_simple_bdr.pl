# Test simple bidirectional logical replication behavior with row filtering
# ID is meant to be something like uuid (e.g. from pgcrypto), but integer
# type is used for simplicity.
use strict;
use warnings;
use PostgresNode;
use TestLib;
use Test::More tests => 10;

our $node_cloud;
our $node_remote;
our $cloud_appname = 'cloud_sub';
our $remote_appname = 'remote_sub';

sub check_data_consistency
{
	my $test_name = shift;
	my $query = shift;
	my $true_result = shift;
	my $result;

	$node_cloud->wait_for_catchup($remote_appname);
	$node_remote->wait_for_catchup($cloud_appname);

	$result =
	$node_remote->safe_psql('postgres', $query);
	is($result, $true_result, $test_name . ' on remote');
	$result =
	$node_cloud->safe_psql('postgres', $query);
	is($result, $true_result, $test_name . ' on cloud');

	return;
}

# Create cloud node
$node_cloud = get_new_node('publisher');
$node_cloud->init(allows_streaming => 'logical');
$node_cloud->start;

# Create remote node
$node_remote = get_new_node('subscriber');
$node_remote->init(allows_streaming => 'logical');
$node_remote->start;

# Test tables
my $users_table = "CREATE TABLE users (
						id integer primary key,
						name text,
						is_cloud boolean
					);";
my $docs_table = "CREATE TABLE docs (
						id integer primary key,
						user_id integer,
						FOREIGN KEY (user_id) REFERENCES users (id),
						content text,
						is_cloud boolean
					);";

# Setup structure on cloud server
$node_cloud->safe_psql('postgres', $users_table);

# Setup structure on remote server
$node_remote->safe_psql('postgres', $users_table);

# Put in initial data
$node_cloud->safe_psql('postgres',
	"INSERT INTO users (id, name, is_cloud) VALUES (1, 'user1_on_cloud', TRUE);");
$node_remote->safe_psql('postgres',
	"INSERT INTO users (id, name, is_cloud) VALUES (2, 'user2_on_remote', FALSE);");
$node_remote->safe_psql('postgres',
	"INSERT INTO users (id, name, is_cloud) VALUES (100, 'user100_local_on_remote', TRUE);");

# Setup logical replication
$node_cloud->safe_psql('postgres', "CREATE PUBLICATION cloud;");
$node_cloud->safe_psql('postgres', "ALTER PUBLICATION cloud ADD TABLE users WHERE (is_cloud IS TRUE);");

$node_remote->safe_psql('postgres', "CREATE PUBLICATION remote;");
$node_remote->safe_psql('postgres', "ALTER PUBLICATION remote ADD TABLE users WHERE (is_cloud IS FALSE);");

my $cloud_connstr = $node_cloud->connstr . ' dbname=postgres';
$node_remote->safe_psql('postgres',
	"CREATE SUBSCRIPTION cloud_to_remote CONNECTION '$cloud_connstr application_name=$remote_appname' PUBLICATION cloud"
);

my $remote_connstr = $node_remote->connstr . ' dbname=postgres';
$node_cloud->safe_psql('postgres',
	"CREATE SUBSCRIPTION remote_to_cloud CONNECTION '$remote_connstr application_name=$cloud_appname' PUBLICATION remote"
);

# Wait for initial table sync to finish
my $synced_query =
"SELECT count(1) = 0 FROM pg_subscription_rel WHERE srsubstate NOT IN ('r', 's');";
$node_remote->poll_query_until('postgres', $synced_query)
  or die "Timed out while waiting for remote to synchronize data";
$node_cloud->poll_query_until('postgres', $synced_query)
  or die "Timed out while waiting for cloud to synchronize data";

$node_cloud->wait_for_catchup($remote_appname);
$node_remote->wait_for_catchup($cloud_appname);

# Test initial table sync
my $result =
  $node_remote->safe_psql('postgres', "SELECT count(*) from users");
is($result, qq(3), 'check initial table sync on remote');
$result =
  $node_cloud->safe_psql('postgres', "SELECT count(*) from users");
is($result, qq(2), 'check initial table sync on cloud');

# Test BDR
$node_cloud->safe_psql('postgres',
	"INSERT INTO users (id, name, is_cloud) VALUES (3, 'user3_on_cloud', TRUE);");
$node_cloud->safe_psql('postgres',
	"INSERT INTO users (id, name, is_cloud) VALUES (4, 'user4_on_cloud', TRUE);");
$node_remote->safe_psql('postgres',
	"INSERT INTO users (id, name, is_cloud) VALUES (5, 'user5_on_remote', FALSE);");

$node_cloud->wait_for_catchup($remote_appname);
$node_remote->wait_for_catchup($cloud_appname);

$result =
  $node_remote->safe_psql('postgres', "SELECT id, name, is_cloud FROM users ORDER BY id;");
is($result, qq(1|user1_on_cloud|t
2|user2_on_remote|f
3|user3_on_cloud|t
4|user4_on_cloud|t
5|user5_on_remote|f
100|user100_local_on_remote|t), 'check users on remote');
$result =
  $node_cloud->safe_psql('postgres', "SELECT id, name, is_cloud FROM users ORDER BY id;");
is($result, qq(1|user1_on_cloud|t
2|user2_on_remote|f
3|user3_on_cloud|t
4|user4_on_cloud|t
5|user5_on_remote|f), 'check users on cloud');

# Add table to cloud server
$node_cloud->safe_psql('postgres', $docs_table);

# Add table to remote server
$node_remote->safe_psql('postgres', $docs_table);

# Put in initial data
$node_cloud->safe_psql('postgres',
	"INSERT INTO docs (id, user_id, content, is_cloud) VALUES (1, 3, 'user3__doc1_on_cloud', TRUE);");

# Add table to publication
$node_cloud->safe_psql('postgres', "ALTER PUBLICATION cloud ADD TABLE docs WHERE (is_cloud IS TRUE);");
$node_remote->safe_psql('postgres', "ALTER PUBLICATION remote ADD TABLE docs WHERE (is_cloud IS FALSE);");

# Refresh
$node_cloud->safe_psql('postgres', "ALTER SUBSCRIPTION remote_to_cloud REFRESH PUBLICATION;");
$node_remote->safe_psql('postgres', "ALTER SUBSCRIPTION cloud_to_remote REFRESH PUBLICATION;");

# Test BDR on new table
$node_cloud->safe_psql('postgres',
	"INSERT INTO docs (id, user_id, content, is_cloud) VALUES (2, 3, 'user3__doc2_on_cloud', TRUE);");
$node_remote->safe_psql('postgres',
	"INSERT INTO docs (id, user_id, content, is_cloud) VALUES (3, 3, 'user3__doc3_on_remote', FALSE);");

check_data_consistency(
	'check docs after insert',
	"SELECT id, user_id, content, is_cloud FROM docs WHERE user_id = 3 ORDER BY id;",
	qq(1|3|user3__doc1_on_cloud|t
2|3|user3__doc2_on_cloud|t
3|3|user3__doc3_on_remote|f)
);

# Test update of remote doc on cloud and vice versa
$node_cloud->safe_psql('postgres',
	"UPDATE docs SET content = 'user3__doc3_on_remote__updated', is_cloud = TRUE WHERE id = 3;");
$node_remote->safe_psql('postgres',
	"UPDATE docs SET content = 'user3__doc2_on_cloud__to_be_deleted', is_cloud = FALSE WHERE id = 2;");

check_data_consistency(
	'check docs after update',
	"SELECT id, user_id, content, is_cloud FROM docs WHERE user_id = 3 ORDER BY id;",
	qq(1|3|user3__doc1_on_cloud|t
2|3|user3__doc2_on_cloud__to_be_deleted|f
3|3|user3__doc3_on_remote__updated|t)
);

# Test delete
$node_remote->safe_psql('postgres',
	"DELETE FROM docs WHERE id = 2;");

check_data_consistency(
	'check docs after delete',
	"SELECT id, user_id, content, is_cloud FROM docs WHERE user_id = 3 ORDER BY id;",
	qq(1|3|user3__doc1_on_cloud|t
3|3|user3__doc3_on_remote__updated|t)
);

$node_remote->stop('fast');
$node_cloud->stop('fast');
