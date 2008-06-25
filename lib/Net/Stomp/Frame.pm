package Net::Stomp::Frame;
use strict;
use warnings;
use base 'Class::Accessor::Fast';
__PACKAGE__->mk_accessors(qw(command headers body));

sub as_string {
    my $self    = shift;
    my $command = $self->command;
    my $headers = $self->headers;
    my $body    = $self->body;
    my $frame   = $command . "\n";

    # insert a content-length header
    my $bytes_message = 0;
    if ( $headers->{bytes_message} ) {
        $bytes_message = 1;
        delete $headers->{bytes_message};
        $headers->{"content-length"} = length( $self->body );
    }

    while ( my ( $key, $value ) = each %{ $headers || {} } ) {
        $frame .= $key . ':' . $value . "\n";
    }

    $body ||= '';
    return "$frame\n$body\000";
}

sub parse {
    my ( $class, $string ) = @_;
    my ( $command, $headers, $body );

    my @failure = ( $string, undef );

    ( $command, $string ) = split( "\n", $string, 2 );
    return @failure unless $command;

    while (1) {
        my ( $header, $key, $val );
        ( $header, $string ) = split( "\n", $string, 2 );
        last unless $header;
        ( $key, $val ) = split( /: */, $header, 2 );
        $headers->{$key} = $val;
    }

    if ( my $length = $headers->{'content-length'} ) {
        return @failure unless length($string) >= $length;
        $headers->{bytes_message} = 1;
        $body = substr( $string, 0, $length );
        $string = substr( $string, $length + 1 );    # +1 to eat trailing null
    } else {
        return @failure unless $string =~ "\000";
        ( $body, $string ) = split( "\000", $string, 2 );
    }

    my $frame = Net::Stomp::Frame->new(
        {   command => $command,
            headers => $headers,
            body    => $body,
        }
    );
    return ( $string, $frame );
}

1;

__END__

=head1 NAME

Net::Stomp::Frame - A STOMP Frame

=head1 SYNOPSIS

  use Net::Stomp::Frame;
  my $frame = Net::Stomp::Frame->new( {
    command => $command,
    headers => $headers,
    body    => $body,
  } );
  my $frame  = Net::Stomp::Frame->parse($string);
  my $string = $frame->as_string;
  
=head1 DESCRIPTION

This module encapulates a Stomp frame. Stomp is the Streaming Text
Orientated Messaging Protocol (or the Protocol Briefly Known as TTMP
and Represented by the symbol :ttmp). It's a simple and easy to
implement protocol for working with Message Orientated Middleware from
any language. L<Net::Stomp> is useful for talking to Apache
ActiveMQ, an open source (Apache 2.0 licensed) Java Message Service
1.1 (JMS) message broker packed with many enterprise features.

A Stomp frame consists of a command, a series of headers and a body.

For details on the protocol see L<http://stomp.codehaus.org/Protocol>.

=head1 METHODS

=head2 new

Create a new L<Net::Stomp::Frame> object:

  my $frame = Net::Stomp::Frame->new( {
    command => $command,
    headers => $headers,
    body    => $body,
  } );

=head2 parse

Create a new L<Net::Stomp::Frame> given a string containing the serialised 
frame:

  my $frame  = Net::Stomp::Frame->parse($string);

If called in scalar context as above, the frame is returned (or undef if the
frame couldn't be parsed).  

In list context, the remainder of the string left over from parsing and the 
frame are returned (or in failure mode, the original string and undef).

  my ($remaining, $frame) = Net::Stomp::Frame->parse($string);

=head2 as_string

Create a string representing the serialized frame:

  my $string = $frame->as_string;

=head1 SEE ALSO

L<Net::Stomp>.

=head1 AUTHOR

Leon Brocard <acme@astray.com>.

=head1 COPYRIGHT

Copyright (C) 2006, Leon Brocard

This module is free software; you can redistribute it or modify it
under the same terms as Perl itself.

