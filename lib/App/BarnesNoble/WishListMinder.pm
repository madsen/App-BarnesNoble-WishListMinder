#---------------------------------------------------------------------
package App::BarnesNoble::WishListMinder;
#
# Copyright 2014 Christopher J. Madsen
#
# Author: Christopher J. Madsen <perl@cjmweb.net>
# Created: 15 Jun 2014
#
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See either the
# GNU General Public License or the Artistic License for more details.
#
# ABSTRACT: Monitor a Barnes & Noble wishlist for price changes
#---------------------------------------------------------------------

use 5.010;
use strict;
use warnings;

our $VERSION = '0.001';
# This file is part of {{$dist}} {{$dist_version}} ({{$date}})

use Path::Tiny;
use Web::Scraper;

use Moo;
use namespace::clean;

#=====================================================================

has mech => qw(is lazy);
sub _build_mech {
  require WWW::Mechanize;
  WWW::Mechanize->new(autocheck => 1);
} # end _build_mech

has dir => qw(is lazy);
sub _build_dir {
  require File::HomeDir;
  File::HomeDir->VERSION(0.93); # my_dist_data

  path(File::HomeDir->my_dist_data('App-BarnesNoble-WishListMinder',
                               { create => 1 })
       or die "Can't determine data directory");
} # end _build_dir

has config_file => qw(is lazy);
sub _build_config_file {
  shift->dir->child('config.ini');
} # end _build_config_file

has config => qw(is lazy);
sub _build_config {
  my $self = shift;
  require Config::Tiny;
  my $fn = $self->config_file;

  Config::Tiny->read("$fn", 'utf8')
        or die "Unable to read $fn: " . Config::Tiny->errstr;
} # end _build_config

has scraper => qw(is lazy);
sub _build_scraper {
  scraper {
    process 'div.wishListItem', 'books[]' => scraper {
      process qw(//h5[1]/a[1] title  TEXT),
      process qw(//h5[1]/em[1]/a[1] author TEXT),
      process qw(div.wishListDateAdded date_added TEXT),
      process qw(//span[@class=~"listPriceValue"] list_price TEXT),
      process qw(//span[@class=~"onlinePriceValue"] price TEXT),
      process qw(//div[@class=~"onlineDiscount"] discount TEXT),
      process '//div[@class=~"eBooksPriority"]/select/option[@selected]',
              qw(priority @value),
    };
    result 'books';
  };
} # end _build_scraper

#---------------------------------------------------------------------
sub login
{
  my ($self) = shift;

  my ($config, $m) = ($self->config->{_}, $self->mech);

  $m->get('https://www.barnesandnoble.com/signin');

  print $m->content;

  $m->submit_form(
    with_fields => {
      'login.email'    => $config->{email},
      'login.password' => $config->{password},
    },
  );
} # end login

#---------------------------------------------------------------------
sub write_csv
{
  my ($self, $outPath, $books) = @_;

  require Text::CSV;

  my $out = $outPath->openw_utf8;

  my $csv = Text::CSV->new( { binary => 1, eol => "\n" } )
    or die "Cannot use CSV: ".Text::CSV->error_diag;

  $csv->print($out, [qw(Title Author), 'Date Added', 'Price', 'List Price', 'Discount', 'Priority']);

  for my $book (@$books) {
    $book->{priority} //= 3;
    for ($book->{discount}) {
      $_ //= '';
      s/^\s+//;
      s/\s+\z//;
      s/^\((.+)\)\z/$1/;
      s/^You save\s*//i;
    }

    $csv->print($out, [ @$book{qw(title author date_added price list_price
                                  discount priority)} ]);
  }

  close $out;
} # end write_csv

#---------------------------------------------------------------------
sub run
{
  my ($self, @args) = @_;

  my $config  = $self->config;
  my $m       = $self->mech;
  my $scraper = $self->scraper;
  my $dir     = $self->dir;

  $self->login;

  for my $wishlist (sort keys %$config) {
    next if $wishlist eq '_';   # the root INI section

    my $response = $m->get( $config->{$wishlist}{wishlist} );
    my $books    = $scraper->scrape($response);
    $self->write_csv($dir->child("$wishlist.csv"), $books);
  }
} # end run

#=====================================================================
# Package Return Value:

1;

__END__

=head1 SYNOPSIS

  use App::BarnesNoble::WishListMinder;
