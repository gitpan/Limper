use Test::HTTP tests => 8;
use Limper;
use strict;
use warnings;

my ($port, $sock);

do {
    $port = int rand()*32767+32768;
    $sock = IO::Socket::INET->new(Listen => 5, ReuseAddr => 1, LocalAddr => 'localhost', LocalPort => $port, Proto => 'tcp')
            or warn "\n# cannot bind to port $port: $!";
} while (!defined $sock);
$sock->shutdown(2);
$sock->close();

my $pid = fork();
if ($pid == 0) {
    my $generic = sub { 'yay' };

    get '/' => $generic;
    post '/' => $generic;

    post qr{^/foo/} => sub {
        status 202, 'whatevs';
        headers Foo => 'bar', Foo => 'buzz', 'Content-Type' => 'text/whee';
        'you posted something: ' . request->{body};
    };

    limp(LocalPort => $port);
    die;
}

my $test = Test::HTTP->new('Limper tests');
my $uri = "http://localhost:$port";

$test->get("$uri/fizz");
$test->status_code_is(404, '404 status');
$test->body_is('This is the void', '404 body');

$test->get("$uri");
$test->status_code_is(200, '200 status');
$test->body_is('yay', '200 body');

$test->post("$uri/foo/bar", [], 'foo=bar');
$test->status_code_is(202, 'post status');
$test->body_is('you posted something: foo=bar', 'post body');
$test->header_is('Foo', 'bar, buzz', 'Foo: bar');
$test->header_is('Content-Type', 'text/whee', 'Content-Type: text/whee');

kill 9, $pid;
