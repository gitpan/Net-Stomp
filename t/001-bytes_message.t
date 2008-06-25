use warnings;
use strict;

use Net::Stomp::Frame;
use Test::More tests => 5;

my $body = '0' . "\000" . '123456789';
my $str  = Net::Stomp::Frame->new(
    {   command => 'MESSAGE',
        headers => {
            'content-length' => 11,
            'destination'    => '/queue/whatever'
        },
        body => $body,
    }
    )->as_string
    . 'gibberish';
my ( $leftovers, $frame ) = Net::Stomp::Frame->parse($str);
is( $frame->command,                'MESSAGE',         'command' );
is( $frame->headers->{destination}, '/queue/whatever', 'destination' );
is( $frame->body,                   $body,             'body' );
ok( $frame->headers->{bytes_message}, 'bytes_message' );
is( $leftovers, 'gibberish', 'leftovers' );
