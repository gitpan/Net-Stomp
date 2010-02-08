#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'Net::STOMP' ) || print "Bail out!
";
}

diag( "Testing Net::STOMP $Net::STOMP::VERSION, Perl $], $^X" );
