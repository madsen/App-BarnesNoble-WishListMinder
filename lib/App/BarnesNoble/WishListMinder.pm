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

use Moo;
use namespace::clean;

# Like == but undef equals only itself
sub _numEq
{
  my ($one, $two) = @_;

  return !1 if (defined($one) xor defined($two));
  return 1 unless defined $one;
  $one == $two;
} # end _numEq

# Like eq but undef equals only itself
sub _eq
{
  my ($one, $two) = @_;

  return !1 if (defined($one) xor defined($two));
  return 1 unless defined $one;
  $one eq $two;
} # end _numEq

sub _format_timestamp {
  require Time::Piece;

  Time::Piece->gmtime(shift)->strftime("%Y-%m-%d %H:%M:%S");
}

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

has db_file => qw(is lazy);
sub _build_db_file {
  shift->dir->child('wishlist.sqlite');
} # end _build_db_file

has dbh => qw(is lazy);
sub _build_dbh {
  my $self = shift;

  require DBI;
  DBI->VERSION(1.38);           # last_insert_id

  my $fn = $self->db_file;
  my $exists = $fn->exists;

  my $dbh = DBI->connect("dbi:SQLite:dbname=$fn","","",
                         { AutoCommit => 0, PrintError => 0, RaiseError => 1,
                           sqlite_unicode => 1 });

  $self->create_database_schema($dbh) unless $exists;

  $dbh;
} # end _build_dbh

has scraper => qw(is lazy);
sub _build_scraper {
  require Web::Scraper::BarnesNoble::WishList;

  Web::Scraper::BarnesNoble::WishList::bn_scraper();
} # end _build_scraper

#---------------------------------------------------------------------
sub create_database_schema
{
  my ($self, $dbh) = @_;

  $dbh->do("PRAGMA foreign_keys = ON");

  $dbh->do(<<'');
CREATE TABLE books (
  ean         INTEGER PRIMARY KEY,
  title       TEXT NOT NULL,
  author      TEXT
)

  $dbh->do(<<'');
CREATE TABLE wishlists (
  wishlist_id   INTEGER PRIMARY KEY,
  url           TEXT NOT NULL UNIQUE,
  last_fetched  TIMESTAMP
)

  $dbh->do(<<'');
CREATE TABLE wishlist_books (
  wishlist_id   INTEGER NOT NULL REFERENCES wishlists,
  ean           INTEGER NOT NULL REFERENCES books,
  priority      INTEGER,
  date_added    DATE NOT NULL DEFAULT CURRENT_DATE,
  date_removed  DATE,
  PRIMARY KEY (wishlist_id,ean)
)

  $dbh->do(<<'');
CREATE TABLE prices (
  ean            INTEGER NOT NULL REFERENCES books,
  first_recorded TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_checked   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  current        TINYINT NOT NULL DEFAULT 1,
  price          INTEGER,
  list_price     INTEGER,
  discount       INTEGER,
  PRIMARY KEY (ean,first_recorded)
)

  $dbh->commit;

} # end create_database_schema

#---------------------------------------------------------------------
sub login
{
  my ($self) = shift;

  my ($config, $m) = ($self->config->{_}, $self->mech);

  $m->get('https://www.barnesandnoble.com/signin');

  #path("/tmp/login.html")->spew_utf8($m->content);

  $m->submit_form(
    with_fields => {
      'login.email'    => $config->{email},
      'login.password' => $config->{password},
    },
  );
} # end login
#---------------------------------------------------------------------

sub scrape_response
{
  my ($self, $response) = @_;

  my $books = $self->scraper->scrape($response);

  for my $book (@$books) {
    $book->{priority} //= 3;
    for ($book->{discount}) {
      next unless defined $_;
      s/^\s+//;
      s/\s+\z//;
      s/^\((.+)\)\z/$1/;
      s/^You save\s*//i;
    }
    $book->{date_added} =~ s!^(\d\d)/(\d\d)/(\d\d)$!20$3-$1-$2!;
  }

  $books;
} # end scrape_response
#---------------------------------------------------------------------

sub write_csv
{
  my ($self, $outPath, $books) = @_;

  require Text::CSV;

  my $out = $outPath->openw_utf8;

  my $csv = Text::CSV->new( { binary => 1, eol => "\n" } )
    or die "Cannot use CSV: ".Text::CSV->error_diag;

  $csv->print($out, [qw(EAN Title Author), 'Date Added', 'Price', 'List Price', 'Discount', 'Priority']);

  for my $book (@$books) {
    $book->{discount} //= '';

    $csv->print($out, [ @$book{qw(ean title author date_added price list_price
                                  discount priority)} ]);
  }

  close $out;
} # end write_csv
#---------------------------------------------------------------------

sub write_db
{
  my ($self, $wishlist_url, $time_fetched, $books) = @_;

  $time_fetched = _format_timestamp($time_fetched);

  my $dbh = $self->dbh;

  my $wishlist_id = $self->get_wishlist_id($wishlist_url);

  my $existing_priority = $self->get_existing_books($wishlist_id);

  my $get_book = $dbh->prepare(<<'');
    SELECT title, author FROM books WHERE ean = ?

  my $get_price = $dbh->prepare(<<'');
    SELECT price, list_price, discount, first_recorded FROM prices
    WHERE ean = ? AND current == 1

  for my $book (@$books) {
    my $ean = $book->{ean};
    my $current_price_row;

    # Update or add the book to the books table
    my $book_row = $dbh->selectrow_hashref($get_book, undef, $ean);
    if ($book_row) {
      # The book exists.  Update title & author if necessary
      unless (_eq($book_row->{title}, $book->{title}) and
              _eq($book_row->{author}, $book->{author})) {
        $dbh->do(<<'', undef, @$book{qw(title author ean)});
          UPDATE books SET title = ?, author = ? WHERE ean = ?

      }
      # Since the book exists, it might have a price
      $current_price_row = $dbh->selectrow_hashref($get_price, undef, $ean);
    } else {
      # The book doesn't exist; add it
      $dbh->do(<<'', undef, @$book{qw(title author ean)});
        INSERT INTO books (title, author, ean) VALUES (?,?,?)

    }

    # Update or add the book to the wishlist_books table
    if (exists $existing_priority->{ $ean }) {
      # The book is already in the wishlist.  Update priority if necessary
      unless (_numEq($book->{priority}, $existing_priority->{ $ean })) {
        $dbh->do(<<'', undef, $book->{priority}, $wishlist_id, $ean);
          UPDATE wishlist_books SET priority = ?
          WHERE wishlist_id = ? AND ean = ?

      }
    } else {
      # Add book to this wishlist
      $dbh->do(<<'', undef, $wishlist_id, @$book{qw(ean priority date_added)});
        INSERT INTO wishlist_books (wishlist_id, ean, priority, date_added)
        VALUES (?,?,?,?)

    }

    for my $price (@$book{qw(price list_price)}) {
      next unless defined $price;
      $price =~ s/^\s*\$//;
      $price = int($price * 100 + 0.5);
    }

    { no warnings 'uninitialized';  $book->{discount} =~ s/\%// }

    # Update or add the prices entry
    if ($current_price_row and
        _numEq($current_price_row->{price}, $book->{price}) and
        _numEq($current_price_row->{list_price}, $book->{list_price}) and
        _numEq($current_price_row->{discount}, $book->{discount})) {
      $dbh->do(<<'', undef, $time_fetched, $ean, $current_price_row->{first_recorded});
        UPDATE prices SET last_checked = ?
        WHERE ean = ? AND first_recorded = ?

    } else {
      if ($current_price_row) {
      $dbh->do(<<'', undef, $ean, $current_price_row->{first_recorded});
        UPDATE prices SET current = 0 WHERE ean = ? AND first_recorded = ?

      }
      say "Inserting $ean";
      $dbh->do(<<'', undef, @$book{qw(ean price list_price discount)}, ($time_fetched)x2);
        INSERT INTO prices (ean, price, list_price, discount, first_recorded, last_checked)
        VALUES (?,?,?,?,?,?)

    }
  } # end for each $book in @$books

  $dbh->commit;
} # end write_db

sub get_existing_books
{
  my ($self, $wishlist_id) = @_;

  my %existing_priority;

  my $s = $self->dbh->prepare(<<'');
    SELECT ean, priority FROM wishlist_books
    WHERE wishlist_id = ? AND date_removed IS NULL

  $s->execute($wishlist_id);
  $s->bind_columns( \( my ($ean, $priority) ) );
  while ($s->fetch) {
    $existing_priority{$ean} = $priority;
  }

  \%existing_priority;
} # end get_existing_books

sub get_wishlist_id
{
  my ($self, $wishlist_url) = @_;

  my $dbh = $self->dbh;

  my ($wishlist_id) = $dbh->selectrow_array(<<'', undef, $wishlist_url);
    SELECT wishlist_id FROM wishlists WHERE url = ?

  unless (defined $wishlist_id) {
    $dbh->do(<<'', undef, $wishlist_url);
      INSERT INTO wishlists (url) VALUES (?)

    $wishlist_id = $dbh->last_insert_id((undef)x4)
        // die "Unable to insert wishlist $wishlist_url";
  }

  $wishlist_id;
} # end get_wishlist_id

#---------------------------------------------------------------------
sub run
{
  my ($self, @args) = @_;

  my $config  = $self->config;
  my $m       = $self->mech;
  my $dir     = $self->dir;

  # Ensure we can open the database before we start making web requests
  $self->dbh;

  $self->login;

  for my $wishlist (sort keys %$config) {
    next if $wishlist eq '_';   # the root INI section

    my $response = $m->get( $config->{$wishlist}{wishlist} );
    my $books    = $self->scrape_response($response);
#    path("/tmp/wishlist.html")->spew_utf8($response->content);
#    $self->write_csv($dir->child("$wishlist.csv"), $books);
    $self->write_db($config->{$wishlist}{wishlist}, $response->last_modified // $response->date, $books);
  }
} # end run

#=====================================================================
# Package Return Value:

1;

__END__

=head1 SYNOPSIS

  use App::BarnesNoble::WishListMinder;
