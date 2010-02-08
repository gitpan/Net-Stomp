#+##############################################################################
#                                                                              #
# File: Net/STOMP/Debug.pm                                                     #
#                                                                              #
# Description: Debug support for Net::STOMP                                    #
#                                                                              #
#-##############################################################################

#
# module definition
#

package Net::STOMP::Debug;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.7 $ =~ /(\d+)\.(\d+)/);

#
# constants
#

use constant API    => 1 << 0;	# STOMP-level API calls
use constant FRAME  => 1 << 1;	# frames sent and received (command only)
use constant HEADER => 1 << 2;	# frames sent and received (headers)
use constant IO     => 1 << 3;	# input/output bytes

#
# global variables
#

our(
    $Flags,			# the current set of debugging flags
);

$Flags = 0;

#
# test if at least one of the given flags is enabled
#

sub enabled ($) {
    my($mask) = @_;

    return($Flags & $mask);
}

#
# report a debugging message
#

sub report ($$@) {
    my($mask, $format, @arguments) = @_;
    my($message);

    return unless $Flags & $mask;
    $message = sprintf($format, @arguments);
    $message =~ s/\s+$//;
    printf(STDERR "# %s\n", $message);
}

1;

__END__

=head1 NAME

Net::STOMP::Debug - Debug support for Net::STOMP

=head1 DESCRIPTION

This module provides debug support for Net::STOMP.

Debug messages are reported using Net::STOMP::Debug::report() and get
printed on STDERR.

The amount of debug information that gets printed can be controlled
using $Net::STOMP::Debug::Flags. Here are the flags that can be used:

=over

=item Net::STOMP::Debug::API

STOMP-level API calls

=item Net::STOMP::Debug::FRAME

frames sent and received (command only)

=item Net::STOMP::Debug::HEADER

frames sent and received (headers)

=item Net::STOMP::Debug::IO

input/output bytes

=back

=head1 AUTHOR

Lionel Cons L<http://cern.ch/lionel.cons>
