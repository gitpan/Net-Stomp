use warnings;
use strict;

use Net::Stomp::Frame;
use Test::More tests => 1;

my $body = "Row, row, row your boat.";

my $frame = Net::Stomp::Frame->new(
    {   command => 'MESSAGE',
        body    => $body,
        headers => { 'message-id' => '12345' },
    }
);

my $str = $frame->as_string;
is( $str, $frame->parse($str)->as_string, 'parse/as_string symmetry' );
