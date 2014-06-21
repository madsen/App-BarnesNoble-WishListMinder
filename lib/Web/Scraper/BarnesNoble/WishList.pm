#---------------------------------------------------------------------
package Web::Scraper::BarnesNoble::WishList;
#
# Copyright 2014 Christopher J. Madsen
#
# Author: Christopher J. Madsen <perl@cjmweb.net>
# Created: 20 Jun 2014
#
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See either the
# GNU General Public License or the Artistic License for more details.
#
# ABSTRACT: Create a Web::Scraper object for a Barnes & Noble wishlist
#---------------------------------------------------------------------

# VERSION
# This file is part of {{$dist}} {{$dist_version}} ({{$date}})

use 5.010;
use strict;
use warnings;

use Web::Scraper;

#=====================================================================
sub bn_scraper
{
  scraper {
    process 'div.wishListItem', 'books[]' => scraper {
      process qw(//input[@name="ItemEan"] ean @value),
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
} # end bn_scraper

#=====================================================================
# Package Return Value:

1;

__END__
