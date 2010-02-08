#+##############################################################################
#                                                                              #
# File: Net/STOMP/Error.pm                                                     #
#                                                                              #
# Description: Error support for Net::STOMP                                    #
#                                                                              #
#-##############################################################################

#
# module definition
#

package Net::STOMP::Error;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.4 $ =~ /(\d+)\.(\d+)/);

#
# global variables
#

our(
    $Message,			# last error message reported
    $Die,			# true if error messages should trigger die()
);

$Die = 1; # by default errors are fatal

#
# report an error message
#

sub report ($@) {
    my($format, @arguments) = @_;

    $Message = sprintf($format, @arguments);
    $Message =~ s/\s+$//;
    die("*** $Message\n") if $Die;
}

1;

__END__

=head1 NAME

Net::STOMP::Error - Error support for Net::STOMP

=head1 DESCRIPTION

This module provides error support for Net::STOMP.

All the functions and methods that can fail use this module to report
errors (using Net::STOMP::Error::report()) and then they return an
undefined value. They also try to return true on success but this is
not always the case as sometimes zero is a possible return value.

By default, errors are fatal and get reported via die().

If $Net::STOMP::Error::Die is false, die() is not used and it is up to
the caller to check the returned value to detect an error (by checking
if the returned value is defined). The caller can then retrieve the
last error message which is always stored in
$Net::STOMP::Error::Message.

=head1 AUTHOR

Lionel Cons L<http://cern.ch/lionel.cons>
