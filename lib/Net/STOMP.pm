#+##############################################################################
#                                                                              #
# File: Net/STOMP.pm                                                           #
#                                                                              #
# Description: STOMP object oriented module for Perl                           #
#                                                                              #
#-##############################################################################

#
# module definition
#

package Net::STOMP;
use strict;
use warnings;
our $VERSION = sprintf("%d.%02d", q$Revision: 1.49 $ =~ /(\d+)\.(\d+)/);

#
# used modules
#

use IO::Socket::INET;
use List::Util qw(shuffle);
use Net::STOMP::Debug;
use Net::STOMP::Error;
use Net::STOMP::Frame;
use Net::STOMP::IO;

#
# Object Oriented definition
#

use Net::STOMP::OO;
our(@ISA) = qw(Net::STOMP::OO);
Net::STOMP::OO::methods(qw(uri host port timeout sockopts callbacks session
			   _io _id _serial _receipts));

#
# global variables
#

our(
    %Callback,			# default callbacks for the class
);

#+++############################################################################
#                                                                              #
# low-level API                                                                #
#                                                                              #
#---############################################################################

# FIXME: check and use $self->timeout() where this makes sense...

#
# try to connect to the server (socket level only)
#

sub _new_socket ($$$%) {
    my($proto, $host, $port, %sockopts) = @_;
    my($me, $socket);

    # initial checks
    $me = "Net::STOMP->new()";
    $sockopts{Proto} = "tcp"; # yes, even SSL is TCP...
    $sockopts{PeerAddr} = $host;
    $sockopts{PeerPort} = $port;
    # from now on, the errors are non-fatal and checked by the caller...
    local $Net::STOMP::Error::Die = 0;
    # try to connect
    if ($proto =~ /\b(ssl)\b/) {
	# with SSL
	unless ($INC{"IO/Socket/SSL.pm"}) {
	    eval { require IO::Socket::SSL };
	    if ($@) {
		Net::STOMP::Error::report("%s: cannot load IO::Socket::SSL: %s", $me, $@);
		return();
	    }
	}
	$socket = IO::Socket::SSL->new(%sockopts);
	unless ($socket) {
	    Net::STOMP::Error::report("%s: cannot SSL connect to %s:%d: %s",
				      $me, $sockopts{PeerAddr}, $sockopts{PeerPort},
				      IO::Socket::SSL::errstr());
	    return();
	}
    } else {
	# with TCP
	$socket = IO::Socket::INET->new(%sockopts);
	unless ($socket) {
	    Net::STOMP::Error::report("%s: cannot connect to %s:%d: %s",
				      $me, $sockopts{PeerAddr}, $sockopts{PeerPort}, $!);
	    return();
	}
	unless (binmode($socket)) {
	    Net::STOMP::Error::report("%s: cannot binmode(socket): %s", $me, $!);
	    return();
	}
    }
    # so far so good...
    return($socket);
}

#
# check and handle the uri opion
#
# see: http://activemq.apache.org/failover-transport-reference.html
#

sub _handle_uri ($) {
    my($string) = @_;
    my($me, @uris, $uri, $path, $fh, $line, @list, @servers);

    $me = "Net::STOMP->new()";
    @uris = ($string);
    while (@uris) {
	$uri = shift(@uris);
	if ($uri =~ /^file:(.+)$/) {
	    # list of uris stored in a file, one per line
	    @list = ();
	    $path = $1;
	    unless (open($fh, "<", $path)) {
		Net::STOMP::Error::report("%s: cannot open %s: %s", $me, $path, $!);
		return();
	    }
	    while (defined($line = <$fh>)) {
		$line =~ s/\#.*//;
		$line =~ s/\s+//g;
		push(@list, $line) if length($line);
	    }
	    unless (close($fh)) {
		Net::STOMP::Error::report("%s: cannot close %s: %s", $me, $path, $!);
		return();
	    }
	    unshift(@uris, @list);
	} elsif ($uri =~ /^failover:(\/\/)?\(([\w\.\-\:\/\,]+)\)(\?[\w\=\-\&]+)?$/) {
	    # failover with options (only "randomize" is supported)
	    @list = split(/,/, $2);
	    @list = shuffle(@list) unless $3 and $3 =~ /\b(randomize=false)\b/;
	    unshift(@uris, @list);
	} elsif ($uri =~ /^failover:([\w\.\-\:\/\,]+)$/) {
	    # failover without options (randomized by default)
	    @list = split(/,/, $1);
	    unshift(@uris, shuffle(@list));
	} elsif ($uri =~ /^(tcp|ssl|stomp|stomp\+ssl):\/\/([\w\.\-]+):(\d+)\/?$/) {
	    # well-formed uri
	    push(@servers, {
		proto => $1,
		host  => $2,
		port  => $3,
	    });
	} else {
	    Net::STOMP::Error::report("%s: unexpected server uri: %s", $me, $string);
	    return();
	}
    }
    unless (@servers) {
	Net::STOMP::Error::report("%s: empty server uri: %s", $me, $string);
	return();
    }
    return(@servers);
}

#
# create a new STOMP object and connect to the server (socket level only)
#

sub new : method {
    my($class, %data) = @_;
    my($me, $self, %sockopts, @uris, $uri, @servers, $server, $socket, $io);

    $me = "Net::STOMP->new()";
    $self = $class->SUPER::new(%data);
    %sockopts = %{ $self->sockopts() } if $self->sockopts();
    $sockopts{SSL_use_cert} = 1 if $sockopts{SSL_cert_file} or $sockopts{SSL_key_file};
    if ($self->uri()) {
	if ($self->host()) {
	    Net::STOMP::Error::report("%s: unexpected server host: %s", $me, $self->host());
	    return();
	}
	if ($self->port()) {
	    Net::STOMP::Error::report("%s: unexpected server port: %s", $me, $self->port());
	    return();
	}
	@servers = _handle_uri($self->uri());
	return() unless @servers;
	# use by default a shorter (but hard-coded) timeout in case we use failover...
	$sockopts{Timeout} = 1 if @servers > 1 and not $sockopts{Timeout};
    } else {
	unless ($self->host()) {
	    Net::STOMP::Error::report("%s: missing server host", $me);
	    return();
	}
	unless ($self->port()) {
	    Net::STOMP::Error::report("%s: missing server port", $me);
	    return();
	}
	@servers = ({
	    proto => grep(/^SSL_/, keys(%sockopts)) ? "ssl" : "tcp",
	    host  => $self->host(),
	    port  => $self->port(),
	});
    }
    foreach $server (@servers) {
	$socket = _new_socket($server->{proto}, $server->{host}, $server->{port}, %sockopts);
	last if $socket;
    }
    unless ($socket) {
	Net::STOMP::Error::report("%s", $Net::STOMP::Error::Message);
	return();
    }
    # regardless of what we've been given, always record peer information this way
    $self->host($socket->peerhost());
    $self->port($socket->peerport());
    # final setup steps
    $io = Net::STOMP::IO->new($socket) or return();
    $self->_io($io);
    unless ($self =~ /\(0x(\w+)\)/) {
	Net::STOMP::Error::report("%s: unexpected Perl object: %s", $me, $self);
	return();
    }
    $self->_id(sprintf("%s-%x-%x-%x", $1, time(), $$, int(rand(65536))));
    $self->_serial(0);
    $self->_receipts({});
    $self->callbacks({});
    return($self);
}

#
# try to send one frame (the frame is always checked, this is currently a feature)
#
# if the frame has a "receipt" header, its value will be remembered to be used
# later in _default_receipt_callback() and/or wait_for_receipts()
#

sub send_frame : method {
    my($self, $frame, $timeout) = @_;
    my($done, $receipt);

    # always check the sent frame
    $frame->check() or return();
    # keep track of receipts
    $receipt = $frame->header("receipt");
    $self->_receipts()->{$receipt}++ if $receipt;
    # encode the frame and send it
    $frame->debug(" sending") if $Net::STOMP::Debug::Flags;
    $done = $self->_io()->send_data($frame->encode(), $timeout);
    return($done) unless $done;
    return($frame);
}

#
# try to receive one frame (the frame is always checked, this is currently a feature)
#

sub receive_frame : method {
    my($self, $timeout) = @_;
    my($buffer, $done, $frame);

    # first try to use the current buffer
    $buffer = $self->_io()->_buffer();
    $frame = Net::STOMP::Frame::decode($buffer);
    return() unless defined($frame);
    unless ($frame) {
	# not enough data in buffer for a complete frame
	$done = $self->_io()->receive_data($timeout);
	return($done) unless $done;
	$buffer = $self->_io()->_buffer();
	# try once more with new buffer
	$frame = Net::STOMP::Frame::decode($buffer);
	return() unless defined($frame);
	return(0) unless $frame;
    }
    # update the buffer (which must have changed)
    $self->_io()->_buffer($buffer);
    # always check the received frame
    $frame->check() or return();
    # so far so good
    $frame->debug(" received") if $Net::STOMP::Debug::Flags;
    return($frame);
}

#
# wait for new frames and dispatch them (see POD for more information)
#

sub wait_for_frames : method {
    my($self, %option) = @_;
    my($timeout, $callback, $limit, $frame, $result);

    $callback = $option{callback};
    $timeout = $option{timeout};
    $limit = time() + $timeout if defined($timeout);
    while (1) {
	$frame = $self->receive_frame($timeout);
	return() unless defined($frame);
	if ($frame) {
	    # we always call first the per-command callback
	    $result = $self->dispatch_frame($frame);
	    return() unless defined($result);
	    if ($callback) {
		# user callback: we stop if callback returns error or true or if once
		$result = $callback->($self, $frame);
		return($result) if not defined($result) or $result or $option{once};
	    } else {
		# no user callback: we stop on the first frame and return it
		return($frame);
	    }
	}
	return(0) if defined($timeout) and time() > $limit;
    }
    # not reached...
    die("ooops!");
}

#
# wait for all receipts to be received
#

sub wait_for_receipts : method {
    my($self, %option) = @_;
    my($callback);

    return(0) unless $self->receipts();
    $option{callback} = sub { return($self->receipts() == 0) };
    return($self->wait_for_frames(%option));
}

#
# return a universal pseudo-unique id to be used in receipts and transactions
#

sub uuid : method {
    my($self) = @_;

    $self->_serial($self->_serial() + 1);
    return(sprintf("%s-%x", $self->_id(), $self->_serial()));
}

#
# return the list of not-yet-received receipts
#

sub receipts : method {
    my($self) = @_;

    return(keys(%{ $self->_receipts() }));
}

#
# object destructor
#

sub DESTROY {
    my($self) = @_;

    $self->disconnect() if $self->session();
}

#+++############################################################################
#                                                                              #
# callback handling                                                            #
#                                                                              #
#---############################################################################

#
# user-friendly accessors for the callbacks
#

sub _any_callback : method {
    my($self, $command, $callback) = @_;
    my($callbacks);

    $callbacks = $self->callbacks() || {};
    return($callbacks->{$command})
	unless $callback;
    $callbacks->{$command} = $callback;
    $self->callbacks($callbacks);
    return($callback);
}

sub connected_callback : method {
    my($self, $callback) = @_;

    return($self->_any_callback("CONNECTED", $callback));
}

sub error_callback : method {
    my($self, $callback) = @_;

    return($self->_any_callback("ERROR", $callback));
}

sub message_callback : method {
    my($self, $callback) = @_;

    return($self->_any_callback("MESSAGE", $callback));
}

sub receipt_callback : method {
    my($self, $callback) = @_;

    return($self->_any_callback("RECEIPT", $callback));
}

#
# report an error about an unexpected server frame received
#

sub _unexpected_frame ($$) {
    my($frame, $info) = @_;

    $info ||= "?";
    Net::STOMP::Error::report("unexpected %s frame received: %s", $frame->command(), $info);
}

#
# default CONNECTED frame callback: keep track of the session identifier
#

sub _default_connected_callback ($$) {
    my($self, $frame) = @_;

    unless ($self->session()) {
	$self->session($frame->header("session"));
	return($self);
    }
    _unexpected_frame($frame, $frame->header("session"));
    return();
}
$Callback{CONNECTED} = \&_default_connected_callback;

#
# default ERROR frame callback: report the error using Net::STOMP::Error::report()
#

sub _default_error_callback ($$) {
    my($self, $frame) = @_;

    # FIXME: what shall we do with the message body?
    _unexpected_frame($frame, $frame->header("message"));
    return();
}
$Callback{ERROR} = \&_default_error_callback;

#
# default MESSAGE frame callback: complain (this must be overwritten by the caller)
#

sub _default_message_callback ($$) {
    my($self, $frame) = @_;

    _unexpected_frame($frame, $frame->header("message-id"));
    return();
}
$Callback{MESSAGE} = \&_default_message_callback;

#
# default RECEIPT frame callback: keep track of received receipts
#
# note: the send_frame() method keeps track of sent receipts
#

sub _default_receipt_callback ($$) {
    my($self, $frame) = @_;
    my($receipts, $id);

    $receipts = $self->_receipts();
    $id = $frame->header("receipt-id");
    if ($receipts and $id and $receipts->{$id}) {
	# good: this is an expected receipt
	delete($receipts->{$id});
	return($self);
    }
    _unexpected_frame($frame, $id);
    return();
}
$Callback{RECEIPT} = \&_default_receipt_callback;

#
# dispatch one received frame, calling the appropriate callback
# (either user supplied or per-class default)
#

sub dispatch_frame : method {
    my($self, $frame) = @_;
    my($command, $callbacks, $callback);

    $command = $frame->command();
    $callbacks = $self->callbacks() || {};
    $callback = $callbacks->{$command} || $Callback{$command};
    unless ($callback) {
	_unexpected_frame($frame, "unexpected command");
	return();
    }
    return($callback->($self, $frame));
}

#+++############################################################################
#                                                                              #
# high-level API (each method matches a client command)                        #
#                                                                              #
#---############################################################################

#
# check that there is an ongoing session
#

sub _check_session : method {
    my($self) = @_;
    my($caller);

    $caller = (caller(1))[3];
    $caller =~ s/^(.+)::/$1->/;
    unless ($self->session()) {
	Net::STOMP::Error::report("%s(): not connected", $caller);
	return();
    }
    return($self);
}

#
# check that there is _not_ an ongoing session
#

sub _check_not_session : method {
    my($self) = @_;
    my($caller);

    $caller = (caller(1))[3];
    $caller =~ s/^(.+)::/$1->/;
    if ($self->session()) {
	Net::STOMP::Error::report("%s(): already connected with session: %s",
				  $caller, $self->session());
	return();
    }
    return($self);
}

#
# trace the high-level method calls
#

sub _trace : method {
    my($self) = @_;
    my($caller);

    $caller = (caller(1))[3];
    $caller =~ s/^(.+)::/$1->/;
    Net::STOMP::Debug::report(Net::STOMP::Debug::API, "%s()", $caller);
}

#
# connect to server
#

sub connect : method {
    my($self, %option) = @_;
    my($frame, $session);

    $self->_trace() if $Net::STOMP::Debug::Flags;
    $self->_check_not_session() or return();
    $option{login} = "" unless defined($option{login});
    $option{passcode} = "" unless defined($option{passcode});
    $frame = Net::STOMP::Frame->new(
        command => "CONNECT",
	headers => \%option,
    );
    $self->send_frame($frame) or return();
    $session = $self->wait_for_frames(
        callback => sub { return($self->session()) },
	timeout  => 10,
    );
    return($self) if $session;
    Net::STOMP::Error::report("Net::STOMP->connect(): no CONNECTED frame received");
    return();
}

#
# disconnect from server (no options/headers supported)
#

sub disconnect : method {
    my($self) = @_;
    my($frame);

    $self->_trace() if $Net::STOMP::Debug::Flags;
    $self->_check_session() or return();
    # send a DISCONNECT frame
    $frame = Net::STOMP::Frame->new(command => "DISCONNECT");
    $self->send_frame($frame) or return();
    # additional bookkeeping
    $self->session("");
    # FIXME: close the socket and mark the object as not usable anymore
    # FIXME: warning if the buffer is not empty, we may have unprocessed frames...
    return($self);
}

#
# subscribe to something
#

sub subscribe : method {
    my($self, %option) = @_;
    my($frame);

    $self->_trace() if $Net::STOMP::Debug::Flags;
    $self->_check_session() or return();
    # send a SUBSCRIBE frame
    $frame = Net::STOMP::Frame->new(
        command => "SUBSCRIBE",
	headers => \%option,
    );
    $self->send_frame($frame) or return();
    return($self);
}

#
# unsubscribe from something
#

sub unsubscribe : method {
    my($self, %option) = @_;
    my($frame);

    $self->_trace() if $Net::STOMP::Debug::Flags;
    $self->_check_session() or return();
    # send a UNSUBSCRIBE frame
    $frame = Net::STOMP::Frame->new(
        command => "UNSUBSCRIBE",
	headers => \%option,
    );
    $self->send_frame($frame) or return();
    return($self);
}

#
# send a message somewhere
#

sub send : method {
    my($self, %option) = @_;
    my($frame, $body);

    $self->_trace() if $Net::STOMP::Debug::Flags;
    $self->_check_session() or return();
    # the body can be given via %option, we move it out
    $body = $option{body};
    delete($option{body});
    # send a SEND frame
    $frame = Net::STOMP::Frame->new(
        command => "SEND",
	headers => \%option,
    );
    $frame->body($body) if defined($body);
    $self->send_frame($frame) or return();
    return($self);
}

#
# acknowledge the reception of a message
#

sub ack : method {
    my($self, %option) = @_;
    my($frame);

    $self->_trace() if $Net::STOMP::Debug::Flags;
    $self->_check_session() or return();
    # the message id can be given via a frame object in %option
    if ($option{frame}) {
	$option{"message-id"} = $option{frame}->header("message-id");
	delete($option{frame});
    }
    # send a ACK frame
    $frame = Net::STOMP::Frame->new(
        command => "ACK",
	headers => \%option,
    );
    $self->send_frame($frame) or return();
    return($self);
}

#
# begin/start a transaction
#

sub begin : method {
    my($self, %option) = @_;
    my($frame);

    $self->_trace() if $Net::STOMP::Debug::Flags;
    $self->_check_session() or return();
    # send a BEGIN frame
    $frame = Net::STOMP::Frame->new(
        command => "BEGIN",
	headers => \%option,
    );
    $self->send_frame($frame) or return();
    return($self);
}

#
# commit a transaction
#

sub commit : method {
    my($self, %option) = @_;
    my($frame);

    $self->_trace() if $Net::STOMP::Debug::Flags;
    $self->_check_session() or return();
    # send a COMMIT frame
    $frame = Net::STOMP::Frame->new(
        command => "COMMIT",
	headers => \%option,
    );
    $self->send_frame($frame) or return();
    return($self);
}

#
# abort/rollback a transaction
#

sub abort : method {
    my($self, %option) = @_;
    my($frame);

    $self->_trace() if $Net::STOMP::Debug::Flags;
    $self->_check_session() or return();
    # send a ABORT frame
    $frame = Net::STOMP::Frame->new(
        command => "ABORT",
	headers => \%option,
    );
    $self->send_frame($frame) or return();
    return($self);
}

1;

__END__

=head1 NAME

Net::STOMP - STOMP object oriented module for Perl

=head1 SYNOPSIS

  #
  # simple producer
  #

  use Net::STOMP;

  $stomp = Net::STOMP->new(host => "127.0.0.1", port => 61613);
  $stomp->connect(login => "guest", passcode => "guest");
  $stomp->send(destination => "/queue/test", body => "hello world!");
  $stomp->disconnect();

  #
  # consumer with client side acknowledgment
  #

  use Net::STOMP;

  $stomp = Net::STOMP->new(host => "127.0.0.1", port => 61613);
  $stomp->connect(login => "guest", passcode => "guest");
  # declare a callback to be called for each received message frame
  $stomp->message_callback(sub {
      my($self, $frame) = @_;

      $self->ack(frame => $frame);
      printf("received: %s\n", $frame->body());
      return($self);
  });
  # subscribe to the given queue
  $stomp->subscribe(destination => "/queue/test", ack => "client");
  # wait for a specified message frame
  $stomp->wait_for_frames(callback => sub {
      my($self, $frame) = @_;

      if ($frame->command() eq "MESSAGE") {
          # stop waiting for new frames if body is "quit"
          return(1) if $frame->body() eq "quit";
      }
      # continue to wait for more frames
      return(0);
  });
  $stomp->subscribe(destination => "/queue/test");
  $stomp->disconnect();

=head1 DESCRIPTION

This module provides an object oriented client interface to interact
with servers supporting STOMP (Streaming Text Orientated Messaging
Protocol). It supports the major features of messaging brokers: SSL,
asynchronous I/O, receipts and transactions.

The new() method can be used to create an object that will later be
used to interact with a server. A Net::STOMP object can have the
following attributes:

=over

=item C<uri>

the Uniform Resource Identifier (URI) specifying where the STOMP
service is and how to connect to it, this can be for instance
C<tcp://msg01:6163> or something more complex such as
C<failover:(ssl://msg01:6162,tcp://msg01:6163)>

=item C<host>

the server name or IP address

=item C<port>

the port number of the STOMP service

=item C<timeout>

a timeout value to be used in some I/O operation (experimental)

=item C<sockopts>

arbitrary socket options (as a hash reference) that will be passed to
IO::Socket::INET->new() or IO::Socket::SSL->new()

=item C<callbacks>

a hash of code references that will be called on each received frame

=item C<session>

the session identifier, once connected

=back

Upon object creation, a TCP connection is made to the server but no
data is exchanged.

Afterwards, the following methods can be used to interact with the
server. They match exactly the different commands that a client frame
can hold:

=over

=item connect()

connect to server

=item disconnect()

disconnect from server

=item subscribe()

subscribe to something

=item unsubscribe()

unsubscribe from something

=item send()

send a message somewhere

=item ack()

acknowledge the reception of a message

=item begin()

begin/start a transaction

=item commit()

commit a transaction

=item abort()

abort/rollback a transaction

=back

All these methods can receive options that will be passed directly as
frame headers. For instance:

  $stomp->subscribe(
      destination => "/queue/test",
      ack         => "client",
  );

Some methods also support other options:

=over

=item send()

C<body>: holds the body of the message to be sent

=item ack()

C<frame>: holds the frame object to acknowledge (its message-id will be used)

=back

Other methods:

=over

=item uuid()

return a universal pseudo-unique identifier to be used for instance in
receipts and transactions

=back

=head1 CALLBACKS

Since STOMP is asynchronous (for instance, MESSAGE frames could be
sent by the server at any time), Net::STOMP uses callbacks to handle
frames. There are in fact two levels of callbacks.

First, there are per-command callbacks that will be called each time a
frame is handled (via the method dispatch_frame()). Net::STOMP
implements default callbacks that should be sufficient for all frames
except MESSAGE frames, which should really be handled by the coder.
These callbacks should return undef on error, something else on success.

Here is an example with a callback counting the messages received:

  $stomp->message_callback(sub {
      my($self, $frame) = @_;

      $MessageCount++;
      return($self);
  });

These callbacks are somehow global and it is good practice not to
change them during a session. If you do not need a global message
callback, you can use:

  $stomp->message_callback(sub { return(1) });

Then, the wait_for_frames() method takes an optional callback argument
holding some code to be called for each received frame, after the
per-command callback has been called. This can be seen as a local
callback, only valid for the call to wait_for_frames(). This callback
must return undef on error, false if more frames are expected or true
if wait_for_frames() can now stop waiting for new frames and return.

Here are all the options that can be given to wait_for_frames():

=over

=item callback

code to be called for each received frame (see above)

=item timeout

time to wait before giving up, undef means wait forever, this is the
default

=item once

wait only for one frame, within the given timeout

=back

The return value of wait_for_frames can be: undef in case of error,
false if no suitable frame has been received, the received frame if
there is no user callback or the user callback return value otherwise.

=head1 LOW-LEVEL API

It should be enough to use the high-level API and use, for instance,
the send() method to create a MESSAGE frame and send it in one go.

If you need lower level interaction, you can manipulate frames with
the Net::STOMP::Frame module.

You can also use:

=over

=item $stomp->send_frame(FRAME, TIMEOUT)

try to send the given frame object within the given TIMEOUT, or
forever if the TIMEOUT is undef

=item $stomp->receive_frame(TIMEOUT)

try to receive a frame within the given TIMEOUT, or forever if the
TIMEOUT is undef

=back

=head1 SSL

If, when using Net::STOMP->new(), some socket options given via
C<sockopts> start with C<SSL_>, IO::Socket::SSL will be used to create
the socket instead of IO::Socket::INET and communication with the
server will go through SSL.

Here are the most commonly used SSL options:

=over

=item SSL_ca_path

path to a directory containing several trusted certificates as
separate files as well as an index of the certificates

=item SSL_key_file

path of your RSA private key

=item SSL_cert_file

path of your certificate

=item SSL_passwd_cb

subroutine that should return the password required to decrypt your
private key

=back

For more information, see L<IO::Socket::SSL>.

=head1 COMPATIBILITY

This module implements the version 1.0 of the protocol (see
L<http://stomp.codehaus.org/Protocol>) as well as well known
extensions for JMS, AMQP, ActiveMQ and RabbitMQ.

It has been tested against both ActiveMQ and RabbitMQ brokers.

=head1 AUTHOR

Lionel Cons L<http://cern.ch/lionel.cons>
