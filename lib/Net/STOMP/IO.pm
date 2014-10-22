#+##############################################################################
#                                                                              #
# File: Net/STOMP/IO.pm                                                        #
#                                                                              #
# Description: Input/Output support for Net::STOMP                             #
#                                                                              #
#-##############################################################################

#
# module definition
#

package Net::STOMP::IO;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.8 $ =~ /(\d+)\.(\d+)/);

#
# Object Oriented definition
#

use Net::STOMP::OO;
our(@ISA) = qw(Net::STOMP::OO);
Net::STOMP::OO::methods(qw(_socket _select _buffer));

#
# used modules
#

use Net::STOMP::Debug;
use Net::STOMP::Error;
use IO::Select;
use UNIVERSAL qw();

#
# constructor
#

sub new : method {
    my($class, $socket) = @_;
    my($self, $select);

    unless ($socket and UNIVERSAL::isa($socket, "IO::Socket")) {
	Net::STOMP::Error::report("Net::STOMP::IO->new(): missing socket");
	return();
    }
    $self = $class->SUPER::new(_socket => $socket);
    $select = IO::Select->new();
    $select->add($socket);
    $self->_select($select);
    $self->_buffer("");
    return($self);
}

#
# try to send the given data
#
# note: this can still hang if the server starts to read something but then
# stops accepting new data before the end; this could happen with huge messages
# but we cannot do much about it since we want frames to be sent atomically...
#

sub send_data : method {
    my($self, $buffer, $timeout) = @_;
    my($me, $length, $done);

    $me = "Net::STOMP::IO::send_data()";
    return(0)
	unless $self->_select()->can_write($timeout);
    $length = length($buffer);
    Net::STOMP::Debug::report(Net::STOMP::Debug::IO, "  sending %d bytes", $length);
    while (length($buffer)) {
	$done = syswrite($self->_socket(), $buffer);
	unless (defined($done)) {
	    Net::STOMP::Error::report("%s: cannot syswrite(): %s", $me, $!);
	    return();
	}
	substr($buffer, 0, $done) = "" if $done;
    }
    return($length)
}

#
# try to receive some data
#
# note: we suck all the available data since we do not know when to stop as we
# have no a priori knowledge on the size of the next frame; this should not be
# a problem in practice; otherwise, we could add an optional max-length parameter
# to avoid reading to much in memory...
#

# FIXME: add a parameter controlling the maximum buffer size (and therefore
# indirectly the maximum frame size...)

sub receive_data : method {
    my($self, $timeout) = @_;
    my($me, $buffer, $length, $done);

    $me = "Net::STOMP::IO::receive_data()";
    return(0)
	unless $self->_select()->can_read($timeout);
    $buffer = $self->_buffer();
    $length = 0;
    while (1) {
	$done = sysread($self->_socket(), $buffer, 8192, length($buffer));
	unless (defined($done)) {
	    Net::STOMP::Error::report("%s: cannot sysread(): %s", $me, $!);
	    return();
	}
	unless ($done) {
	    if ($length) {
		# we read some data already... stop here to process it
		last;
	    } else {
		# no previously read data read and EOF... give up
		Net::STOMP::Error::report("%s: cannot sysread(): EOF", $me);
		return();
	    }
	}
	Net::STOMP::Debug::report(Net::STOMP::Debug::IO, "  received %d bytes", $done);
	$length += $done;
	last unless $self->_select()->can_read(0);
    }
    $self->_buffer($buffer);
    return($length);
}

1;

__END__

=head1 NAME

Net::STOMP::IO - Input/Output support for Net::STOMP

=head1 DESCRIPTION

This module provides Input/Output support for Net::STOMP.

It is used internally by Net::STOMP and is not expected to be used
elsewhere.

=head1 AUTHOR

Lionel Cons L<http://cern.ch/lionel.cons>
