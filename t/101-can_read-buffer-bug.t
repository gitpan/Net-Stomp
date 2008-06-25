use warnings;
use strict;

use IO::Socket::INET;
use Net::Stomp;
use Net::Stomp::Frame;

my $server = IO::Socket::INET->new( Listen => 1 );

sub server_main {
    my $client = $server->accept();
    my $body   = "o hai there";
    foreach my $i ( 1 .. 3 ) {
        use bytes;
        $client->print(
            Net::Stomp::Frame->new(
                {   command => 'MESSAGE',
                    headers => {
                        destination      => '/queue/wordbin',
                        'message-id'     => "$i",
                        'content-length' => bytes::length($body),
                    },
                    body => $body,
                }
                )->as_string
        );
    }
    sleep 1; # leave the socket open long enough for can_read to fail
             # because if you close it, the buffering problem doesn't show up.
    $client->close();
    $server->close();
    exit 0;
}

sub client_main {
    use Test::More tests => 3;
    my $stomp = Net::Stomp->new(
        {   hostname => 'localhost',
            port     => $server->sockport
        }
    );

    # this makes the first frame come in
    $stomp->connect( { login => 'hello', passcode => 'there' } );

    # second frame
    $stomp->receive_frame();

    # we should still be able to read
    ok( $stomp->can_read, 'can_read' );

    # third frame
    $stomp->receive_frame();

    # there should be no frames left
    ok( !$stomp->can_read, 'cannot read' );

    sleep 2;    # wait longer than the server

    eval { $stomp->can_read( { timeout => 3 } ) };
    ok( $@, 'dies on EOF' );
    $stomp->socket->close();
}

if ( my $pid = fork ) {
    client_main();
    waitpid $pid, 0;
} else {
    server_main();
}

