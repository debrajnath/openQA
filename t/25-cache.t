#! /usr/bin/perl

# Copyright (c) 2018-2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

use Mojo::Base -strict;

BEGIN { unshift @INC, 't/lib' }

use Test::More;
use Test::Warnings;
use OpenQA::Utils;
use OpenQA::Utils 'base_host';
use OpenQA::CacheService::Model::Cache;
use IO::Socket::INET;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use Mojo::SQLite;
use Mojo::File qw(path);
use Mojo::Log;
use POSIX '_exit';
use Mojo::IOLoop::ReadWriteProcess qw(queue process);
use Mojo::IOLoop::ReadWriteProcess::Session 'session';
use OpenQA::Test::Utils qw(fake_asset_server);

my $cached   = path()->child('t', 'cache.d');
my $cachedir = $cached->child('cache');
my $db_file  = $cachedir->child('cache.sqlite');
my $port     = Mojo::IOLoop::Server->generate_port;
my $host     = "http://localhost:$port";
$cachedir->remove_tree;
ok($cachedir->make_path, "creating cachedir under $cachedir");

# Capture logs
my $log = Mojo::Log->new;
$log->unsubscribe('message');
my $cache_log = '';
$log->on(
    message => sub {
        my ($log, $level, @lines) = @_;
        $cache_log .= "[$level] " . join "\n", @lines, '';
    });

$SIG{INT} = sub { session->clean };

END { session->clean }

my $server_instance = process sub {
    Mojo::Server::Daemon->new(app => fake_asset_server, listen => [$host], silent => 1)->run;
    _exit(0);
};

sub start_server {
    $server_instance->set_pipes(0)->start;
    sleep 1 while !IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port);
    return;
}

sub stop_server {
    # now kill the worker
    $server_instance->stop();
}

my $cache = OpenQA::CacheService::Model::Cache->new(host => $host, location => $cachedir->to_string, log => $log);

subtest 'base_host' => sub {
    my $cache_test
      = OpenQA::CacheService::Model::Cache->new(host => $host, location => $cachedir->to_string, log => $log);
    is base_host($cache_test->host), 'localhost';
};

is $cache->init, $cache;
is $cache->sqlite->migrations->latest, 1, 'version 1 is the latest version';
is $cache->sqlite->migrations->active, 1, 'version 1 is the active version';
like $cache_log, qr/Creating cache directory tree for/, "Cache directory tree created.";
like $cache_log, qr/Configured limit: 53687091200/,     "Cache limit is default (50GB).";
ok(-e $db_file, "cache.sqlite is present");
$cache_log = '';

$cachedir->child('127.0.0.1')->make_path;
for my $i (1 .. 3) {
    my $file = $cachedir->child('127.0.0.1', "$i.qcow2")->spurt("\0" x 84);
    if ($i % 2) {
        my $sql = "INSERT INTO assets (filename,size, etag,last_use)
                VALUES ( ?, ?, 'Not valid', strftime('\%s','now'));";
        $cache->sqlite->db->query($sql, $file->to_string, 84);
    }
}

$cache->sleep_time(1);
$cache->init;
is $cache->sqlite->migrations->active, 1, 'version 1 is still the active version';
like $cache_log, qr/CACHE: Health: Real size: 168, Configured limit: 53687091200/,
  "Cache limit/size match the expected 100GB/168)";
unlike $cache_log, qr/CACHE: Purging non registered.*[13].qcow2/, "Registered assets 1 and 3 were kept";
like $cache_log,   qr/CACHE: Purging non registered.*2.qcow2/,    "Asset 2 was removed";
$cache_log = '';

$cache->limit(100);
$cache->init;
like $cache_log, qr/CACHE: Health: Real size: 84, Configured limit: 100/, "Cache limit/size match the expected 100/84)";
like $cache_log, qr/CACHE: removed.*1.qcow2/, "Oldest asset (1.qcow2) removal was logged";
like $cache_log , qr/$host/, "Host was initialized correctly ($host).";
ok(!-e "1.qcow2", "Oldest asset (1.qcow2) was sucessfully removed");
$cache_log = '';

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-textmode@64bit.qcow2');
like $cache_log, qr/Downloading sle-12-SP3-x86_64-0368-textmode\@64bit.qcow2 from/, "Asset download attempt";
like $cache_log, qr/failed with: 521/, "Asset download fails with: 521 - Connection refused";
$cache_log = '';

$port = Mojo::IOLoop::Server->generate_port;
$host = "http://127.0.0.1:$port";
start_server;

$cache->host($host);
$cache->limit(1024);
$cache->init;

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-404@64bit.qcow2');
like $cache_log, qr/Downloading sle-12-SP3-x86_64-0368-404\@64bit.qcow2 from/, "Asset download attempt";
like $cache_log, qr/failed with: 404/, "Asset download fails with: 404 - Not Found";
$cache_log = '';

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-400@64bit.qcow2');
like $cache_log, qr/Downloading sle-12-SP3-x86_64-0368-400\@64bit.qcow2 from/, "Asset download attempt";
like $cache_log, qr/failed with: 400/, "Asset download fails with 400 - Bad Request";
$cache_log = '';

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-589@64bit.qcow2');
like $cache_log, qr/Downloading sle-12-SP3-x86_64-0368-589\@64bit.qcow2 from/, "Asset download attempt";
like $cache_log, qr/Expected: 10 \/ Downloaded: 6/,                            "Incomplete download logged";
like $cache_log, qr/CACHE: Error 598, retrying download for 4 more tries/,     "4 tries remaining";
like $cache_log, qr/CACHE: Waiting 1 seconds for the next retry/,              "1 second sleep_time set";
like $cache_log, qr/CACHE: Too many download errors, aborting/,                "Bailing out after too many retries";
$cache_log = '';

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-503@64bit.qcow2');
like $cache_log, qr/Downloading sle-12-SP3-x86_64-0368-503\@64bit.qcow2 from/, "Asset download attempt";
like $cache_log, qr/triggering a retry for 503/, "Asset download fails with 503 - Server not available";
like $cache_log, qr/CACHE: Error 503, retrying download for 4 more tries/, "4 tries remaining";
like $cache_log, qr/CACHE: Waiting 1 seconds for the next retry/,          "1 second sleep_time set";
like $cache_log, qr/CACHE: Too many download errors, aborting/,            "Bailing out after too many retries";
$cache_log = '';

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
like $cache_log, qr/Downloading sle-12-SP3-x86_64-0368-200\@64bit.qcow2 from/, "Asset download attempt";
like $cache_log, qr/CACHE: Asset download successful to .*sle-12-SP3-x86_64-0368-200.*, Cache size is: 1024/,
  "Full download logged";
like $cache_log, qr/ andi \$a3, \$t1, 41399 and 1024/, "Etag and size are logged";
$cache_log = '';

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
like $cache_log, qr/Downloading sle-12-SP3-x86_64-0368-200\@64bit.qcow2 from/, "Asset download attempt";
like $cache_log, qr/CACHE: Content has not changed, not downloading .* but updating last use/, "Upading last use";
$cache_log = '';

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-200@64bit.qcow2');
like $cache_log, qr/Downloading sle-12-SP3-x86_64-0368-200\@64bit.qcow2 from/,      "Asset download attempt";
like $cache_log, qr/sle-12-SP3-x86_64-0368-200\@64bit.qcow2 but updating last use/, "last use gets updated";
$cache_log = '';

$cache->get_asset({id => 922756}, "hdd", 'sle-12-SP3-x86_64-0368-200_256@64bit.qcow2');
like $cache_log, qr/Downloading sle-12-SP3-x86_64-0368-200_256\@64bit.qcow2 from/, "Asset download attempt";
like $cache_log, qr/CACHE: Asset download successful to .*sle-12-SP3-x86_64-0368-200_256.*, Cache size is: 256/,
  "Full download logged";
like $cache_log, qr/ andi \$a3, \$t1, 41399 and 256/, "Etag and size are logged";
like $cache_log, qr/removed.*sle-12-SP3-x86_64-0368-200\@64bit.qcow2*/, "Reclaimed space for new smaller asset";
$cache_log = '';

$cache->track_asset("Foobar", 0);
$cache->sqlite->db->query("delete from assets");

my $fake_asset = $cachedir->child('test.qcow2');
$fake_asset->spurt('');
ok -e $fake_asset, 'Asset is there';
$cache->asset_lookup($fake_asset->to_string);
ok !-e $fake_asset, 'Asset was purged since was not tracked';

$fake_asset->spurt('');
ok -e $fake_asset, 'Asset is there';
$cache->purge_asset($fake_asset->to_string);
ok !-e $fake_asset, 'Asset was purged';

$cache->track_asset($fake_asset->to_string);
is(ref($cache->_asset($fake_asset->to_string)), 'HASH', 'Asset was just inserted, so it must be there')
  or die diag explain $cache->_asset($fake_asset->to_string);

is $cache->_asset($fake_asset->to_string)->{etag}, undef, 'Can get downloading state with _asset()';
is_deeply $cache->_asset('foobar'), {}, '_asset() returns {} if asset is not present';

subtest 'cache directory is symlink' => sub {
    my $symlink = $cached->child('symlink')->to_string;
    unlink($symlink);
    ok(symlink($cachedir, $symlink), "symlinking cache dir to $symlink");
    $fake_asset->spurt('not a real image');
    ok(-e $fake_asset, 'fake asset created');

    $cache->location($symlink);
    $cache->_cache_sync;
    is($cache->{cache_real_size}, 16, 'cache size could be determined');
};

stop_server;

done_testing();
