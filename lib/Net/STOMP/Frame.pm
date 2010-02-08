#+##############################################################################
#                                                                              #
# File: Net/STOMP/Frame.pm                                                     #
#                                                                              #
# Description: Frame support for Net::STOMP                                    #
#                                                                              #
#-##############################################################################

#
# module definition
#

package Net::STOMP::Frame;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.10 $ =~ /(\d+)\.(\d+)/);

#
# Object Oriented definition
#

use Net::STOMP::OO;
our(@ISA) = qw(Net::STOMP::OO);
Net::STOMP::OO::methods(qw(command headers body));

#
# used modules
#

use Net::STOMP::Debug;
use Net::STOMP::Error;

#
# global variables
#

our(
    $CheckLevel,         # level of checking performed by the check() method
    %CommandHeader,	 # hash of expected commands and headers
);

$CheckLevel = 2;

#+++############################################################################
#                                                                              #
# basic frame support                                                          #
#                                                                              #
#---############################################################################

#
# convenient header access method (get only)
#

sub header : method {
    my($self, $key) = @_;
    my($headers);

    $headers = $self->headers();
    return() unless $headers;
    return($headers->{$key});
}

#
# decode the given string and return a complete frame object, if possible
#
# side effect: in case a frame is successfully found, the given string is
# _modified_ to remove the corresponding encoded frame
#
# return zero if no complete frame is found and undef on error
#

sub decode ($) {
    my($string) = @_;
    my($me, $index, $command, $length, $headers, $line, $body, $frame);

    $me = "Net::STOMP::Frame::decode()";
    # look for command
    $index = index($string, "\n", 1);
    return(0) unless $index >= 0;
    # at this point we know we should have at least the command
    # argh! some servers send a spurious newline after the final NULL byte so we
    # may see it at the beginning of the next frame, i.e. here...
    unless ($string =~ /^(\n?([A-Z]{2,16}))\n/) {
	Net::STOMP::Error::report("%s: invalid or missing command", $me);
	return();
    }
    $length = length($1);
    $command = $2;

    # look for headers
    $index = index($string, "\n\n", $length);
    return(0) unless $index >= 0;
    # at this point we know we should have at least the headers
    $headers = {};
    if ($index > $length) {
	foreach $line (split(/\n/, substr($string, $length + 1, $index - $length - 1))) {
	    unless ($line =~ /^((?:[a-z]+[\.\-])*[a-z]+)\s*:\s*(.*?)$/i) {
		Net::STOMP::Error::report("%s: invalid header: %s", $me, $line);
		return();
	    }
	    $headers->{$1} = $2;
	}
    }

    # look for body
    $length = $headers->{"content-length"};
    if (defined($length) and $length =~ /^\d+$/) {
	return(0) unless length($string) >= $index + $length + 3;
	unless (substr($string, $index+2+$length, 1) eq "\0") {
	    Net::STOMP::Error::report("%s: missing NULL byte", $me);
	    return();
	}
    } else {
	$length = index($string, "\0", $index + 2) - $index - 2;
	return(0) unless $length >= 0;
    }
    # at this point we know we should have at least the body
    $body = substr($string, $index + 2, $length);

    # build the frame and truncate the given string
    $frame = Net::STOMP::Frame->new(
        command => $command,
	headers => $headers,
	body    => $body,
    );
    substr($_[0], 0, $index + $length + 3) = "";
    # argh! some servers send a spurious newline after the NULL byte...
    substr($_[0], 0, 1) = "" if length($_[0]) and substr($_[0], 0, 1) eq "\n";

    # so far so good ;-)
    return($frame);
}

#
# encode the given frame object with an optional clh parameter
#  - if defined and true: always set the content-length header
#  - if defined and false: never set the content-length header
#  - if not defined: set the content-length header only if there is a body
#

sub encode : method {
    my($self, $clh) = @_;
    my($string, $headers, $body, $key);

    # setup
    $headers = $self->headers();
    $headers = {} unless defined($headers);
    $body = $self->body();
    $body = "" unless defined($body);

    # handle the content-length header
    $clh = length($body) unless defined($clh);
    if ($clh) {
	$headers->{"content-length"} = length($body);
    } else {
	delete($headers->{"content-length"});
    }

    # encode
    $string = $self->command() . "\n";
    foreach $key (keys(%$headers)) {
	$string .= $key . ":" . $headers->{$key} . "\n";
    }
    $string .= "\n$body\0";

    return($string);
}

#
# debug the given frame
#

sub debug : method {
    my($self, $what) = @_;
    my($headers, $key);

    if (Net::STOMP::Debug::enabled(Net::STOMP::Debug::FRAME)) {
	$what = "seen" unless $what;
	Net::STOMP::Debug::report(-1, "%s %s frame", $what, $self->command());
    }
    if (Net::STOMP::Debug::enabled(Net::STOMP::Debug::HEADER)) {
	$headers = $self->headers();
	$headers = {} unless defined($headers);
	foreach $key (keys(%$headers)) {
	    Net::STOMP::Debug::report(-1, "  | %s: %s", $key, $headers->{$key});
	}
    }
    # FIXME: add the possibility to dump the frame body
}

#+++############################################################################
#                                                                              #
# frame checking                                                               #
#                                                                              #
#---############################################################################

#
# command/headers declarations (http://stomp.codehaus.org/Protocol)
#

# client -> server
$CommandHeader{CONNECT}     = { "login" => 1, "passcode" => 2 };
$CommandHeader{SEND}        = { "destination" => 1, "transaction" => 0 };
$CommandHeader{SUBSCRIBE}   = { "destination" => 1, "selector" => 1, "ack" => 0, "id" => 0 };
$CommandHeader{UNSUBSCRIBE} = { "destination" => 1, "id" => 1 };
$CommandHeader{BEGIN}       = { "transaction" => 1 };
$CommandHeader{COMMIT}      = { "transaction" => 1 };
$CommandHeader{ABORT}       = { "transaction" => 1 };
$CommandHeader{ACK}         = { "message-id" => 1, "transaction" => 0 };
$CommandHeader{DISCONNECT}  = {};

# most client commands can have an optional receipt header
foreach my $command (keys(%CommandHeader)) {
    $CommandHeader{$command}{receipt} = 0
	unless $command eq "CONNECT";
}

# server -> client
$CommandHeader{CONNECTED}   = { "session" => 1 };
$CommandHeader{RECEIPT}     = { "receipt-id" => 1 };
$CommandHeader{MESSAGE}     = { "message-id" => 1, "destination" => 2, "subscription" => 0 };
$CommandHeader{ERROR}       = { "message" => 1 };

# protocol-wise, any frame can have a content-length header
foreach my $command (keys(%CommandHeader)) {
    $CommandHeader{$command}{"content-length"} = 0;
}

# STOMP extensions for JMS message semantics (http://activemq.apache.org/stomp.html)
# plus JMSXUserID (http://activemq.apache.org/jmsxuserid.html)
foreach my $key (qw(correlation-id expires persistent priority reply-to type
		    JMSXGroupID JMSXGroupSeq JMSXUserID)) {
    $CommandHeader{SEND}{$key} = 0;
    $CommandHeader{MESSAGE}{$key} = 0;
}

# ActiveMQ extensions to STOMP (http://activemq.apache.org/stomp.html)
$CommandHeader{CONNECT}{"client-id"} = 0;
foreach my $key (qw(dispatchAsync exclusive maximumPendingMessageLimit noLocal
		    prefetchSize priority retroactive subscriptionName)) {
    $CommandHeader{SUBSCRIBE}{"activemq.$key"} = 0;
}

# ActiveMQ extensions for advisory messages (http://activemq.apache.org/advisory-message.html)
foreach my $key (qw(originBrokerId originBrokerName originBrokerURL orignalMessageId
		    consumerCount producerCount consumerId producerId usageName)) {
    $CommandHeader{MESSAGE}{$key} = 0;
}

# STOMP JMS Bindings (http://stomp.codehaus.org/StompJMS)
$CommandHeader{SUBSCRIBE}{"no-local"} = 0;
$CommandHeader{SUBSCRIBE}{"durable-subscriber-name"} = 0;

# RabbitMQ extensions to STOMP (http://dev.rabbitmq.com/wiki/StompGateway)
foreach my $command (keys(%CommandHeader)) {
    $CommandHeader{$command}{"content-type"} = 0;
}
$CommandHeader{MESSAGE}{exchange} = 0;
$CommandHeader{SUBSCRIBE}{routing_key} = 0;

# other undocumented headers :-(
$CommandHeader{MESSAGE}{timestamp} = 0;
$CommandHeader{MESSAGE}{redelivered} = 0;
$CommandHeader{MESSAGE}{JMSXMessageCounter} = 0;
$CommandHeader{ERROR}{"receipt-id"} = 0;

# and maybe also... (from StompCommandConstants.cpp)
# const std::string StompCommandConstants::HEADER_REQUESTID = "request-id";
# const std::string StompCommandConstants::HEADER_RESPONSEID = "response-id";
# const std::string StompCommandConstants::HEADER_REDELIVERYCOUNT = "redelivery_count";
# const std::string StompCommandConstants::HEADER_TRANSFORMATION = "transformation";
# const std::string StompCommandConstants::HEADER_TRANSFORMATION_ERROR = "transformation-error";

#
# check that the given frame object is valid
#

sub check : method {
    my($self) = @_;
    my($me, $command, $headers, $key, $value, %required);

    # setup
    return($self) unless $CheckLevel > 0;
    $me = "Net::STOMP::Frame::check()";

    # check the command (basic)
    $command = $self->command();
    unless (defined($command)) {
	Net::STOMP::Error::report("%s: missing command", $me);
	return();
    }
    unless ($command =~ /^[A-Z]{2,16}$/) {
	Net::STOMP::Error::report("%s: invalid command: %s", $me, $command);
	return();
    }

    # check the headers (basic)
    $headers = $self->headers();
    if (defined($headers)) {
	unless (ref($headers) eq "HASH") {
	    Net::STOMP::Error::report("%s: invalid headers: %s", $me, $headers);
	    return();
	}
	foreach $key (keys(%$headers)) {
	    unless ($key =~ /^([a-z]+[\.\-])*[a-z]+$/i) {
		Net::STOMP::Error::report("%s: invalid header key: %s", $me, $key);
		return();
	    }
	    unless (defined($headers->{$key})) {
		Net::STOMP::Error::report("%s: missing header value: %s", $me, $key);
		return();
	    }
	}
    }

    # this is all for level 1...
    return($self) unless $CheckLevel > 1;

    # check the command (must be known)
    unless ($CommandHeader{$command}) {
	Net::STOMP::Error::report("%s: unknown command: %s", $me, $command);
	return();
    }

    # check the headers (keys must be known, value must be expected)
    foreach $key (keys(%$headers)) {
	if (exists($CommandHeader{$command}{$key})) {
	    $value = $headers->{$key};
	    # FIXME: add more value checks
	    if ($key =~ /^(content-length|expires|timestamp)$/) {
		next if $value =~ /^\d+$/;
	    } elsif ($key eq "ack") {
		next if $value =~ /^(auto|client)$/;
	    } else {
		next;
	    }
	    Net::STOMP::Error::report("%s: unexpected header value for %s: %s",
				      $me, $key, $value);
	    return();
	} elsif ($CheckLevel > 2) {
	    # level 3 only...
	    Net::STOMP::Error::report("%s: unexpected header key for %s: %s",
				      $me, $command, $key);
	    return();
	}
    }

    # check the headers (all required keys are present)
    foreach $key (keys(%{ $CommandHeader{$command} })) {
	$value = $CommandHeader{$command}{$key};
	$required{$value}{$key}++ if $value;
    }
    foreach $key (keys(%$headers)) {
	$value = $CommandHeader{$command}{$key};
	delete($required{$value}) if $value;
    }
    foreach $value (keys(%required)) {
	$key = join("|", sort(keys(%{ $required{$value} })));
	Net::STOMP::Error::report("%s: missing header key for %s: %s", $me, $command, $key);
	return();
    }

    # FIXME: check the absence/presence of body? e.g. CONNECT -> no body

    # so far so good
    return($self);
}

1;

__END__

=head1 NAME

Net::STOMP::Frame - Frame support for Net::STOMP

=head1 SYNOPSIS

  use Net::STOMP::Frame;

  # create a connection frame
  $frame = Net::STOMP::Frame->new(
      command => "CONNECT",
      headers => {
          login    => "guest",
          passcode => "guest",
      },
  );

  # get the command
  $cmd = $frame->command();

  # set the body
  $frame->body("...some data...");

=head1 DESCRIPTION

This module provides an object oriented interface to manipulate STOMP frames.

A frame object has the following attributes: C<command>, C<headers>
and C<body>. The C<headers> must be a reference to hash of header key,
value pairs.

The check() method verifies that the frame is well-formed. For
instance, it must contain a C<command> made of uppercase letters.
See below for more information.

The header() method can be used to directly access (read only) a given
header key. For instance:

  $msgid = $frame->header("message-id");

The debug() method can be used to dump a frame object on STDERR. So
far, this excludes the frame body.

The decode() function and the encode() method are used internally by
Net::STOMP and are not expected to be used elsewhere.

=head1 FRAME CHECKING

Net::STOMP calls the check() method for every frame about to be sent
and for every received frame.

The global variable $Net::STOMP::Frame::CheckLevel controls the amount
of checking that is performed.

=over

=item 0

nothing is checked

=item 1

the frame must have a good looking command and, if it has headers, the
keys must be good looking and the values must be defined

=item 2 (default)

in addition to level 1, the frame must have a known command and, for
known header keys, their value must be good looking (e.g. the
"timestamp" value must be an integer); also, the presence of mandatory
keys (e.g. "session" for a "CONNECTED" frame) is checked

=item 3

in addition to level 2, all header keys must be known/expected

=back

Violations of these checks trigger errors in the check() method.

=head1 AUTHOR

Lionel Cons L<http://cern.ch/lionel.cons>
