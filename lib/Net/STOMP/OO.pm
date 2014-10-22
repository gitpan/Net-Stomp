#+##############################################################################
#                                                                              #
# File: Net/STOMP/OO.pm                                                        #
#                                                                              #
# Description: Object Oriented support for Net::STOMP                          #
#                                                                              #
#-##############################################################################

#
# module definition
#

package Net::STOMP::OO;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.5 $ =~ /(\d+)\.(\d+)/);

#
# used modules
#

use UNIVERSAL qw();

#
# declare the valid fields/methods that the derived class supports
#

sub methods (@) {
    my(@names) = @_;
    my($class, $name, $sub);

    $class = caller();
    foreach $name (@names) {
	# check the method name
	die("*** invalid method name: $name\n")
	    unless $name =~ /^_?[a-z]+$/;
	# build the accessor method
	$sub = sub {
	    my($self, $value) = @_;
	    die("*** ${class}->${name}(): invalid invocation\n")
		unless @_ == 1 or @_ == 2;
	    $self->{$name} = $value if @_ == 2;
	    return($self->{$name});
	};
	# hook it to the symbol table
	no strict "refs";
	*{"${class}::${name}"} = $sub;
    }
}

#
# inheritable constructor
#

sub new : method {
    my($class, %data) = @_;
    my($self, $key);

    die("*** ${class}->new(): invalid invocation\n")
	unless @_ % 2;
    foreach $key (keys(%data)) {
	die("*** ${class}->new(): unexpected method: $key\n")
	    unless $key =~ /^_?[a-z]+$/ and UNIVERSAL::can($class, $key);
    }
    $self = \%data;
    bless($self, $class);
    return($self);
}

1;

__END__

=head1 NAME

Net::STOMP::OO - Object Oriented support for Net::STOMP

=head1 DESCRIPTION

This module provides Object Oriented support for Net::STOMP.

It implements dual-purpose accessors that can be used to get or set a
given object attribute. For instance:

  # get the frame body
  $body = $frame->body();

  # set the frame body
  $frame->body("...some text...");

It also implements flexible object constructors. For instance:

  $frame = Net::STOMP::Frame->new(
      command => "MESSAGE",
      body    => "...some text...",
  );

is equivalent to:

  $frame = Net::STOMP::Frame->new();
  $frame->command("MESSAGE");
  $frame->body("...some text...");

=head1 AUTHOR

Lionel Cons L<http://cern.ch/lionel.cons>
