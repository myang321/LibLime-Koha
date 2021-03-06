package C4::Circulation;

# Copyright 2000-2002 Katipo Communications
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# Koha; if not, write to the Free Software Foundation, Inc., 59 Temple Place,
# Suite 330, Boston, MA  02111-1307 USA


use strict;
use warnings;
use Carp;

use Koha;
use C4::Context;
use C4::Stats;
use C4::Reserves;
use C4::Koha;
use C4::Biblio;
use C4::Items;
use C4::Members;
use C4::Dates;
use C4::Calendar;
use C4::ItemCirculationAlertPreference;
use C4::LostItems;
use C4::Message;
use C4::Debug;
use C4::Overdues;
use C4::Members;
use Date::Calc qw(
  Today
  Today_and_Now
  Add_Delta_YM
  Add_Delta_DHMS
  Date_to_Days
  Day_of_Week
  Add_Delta_Days    
);
use POSIX qw(strftime);
use C4::Branch; # GetBranches
use C4::Log; # logaction
use Data::Dumper;

use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

BEGIN {
    require Exporter;
    $VERSION = 3.02;    # for version checking
    @ISA    = qw(Exporter);

    # FIXME subs that should probably be elsewhere
    push @EXPORT, qw(
      barcodedecode
        GetRenewalDetails 
    );

    # subs to deal with issuing a book
    push @EXPORT, qw(
        &CanBookBeIssued
        &CanBookBeRenewed
        &AddIssue
        &AddRenewal
        &GetRenewCount
        &GetItemIssue
                &GetOpenIssue
        &GetItemIssues
        &GetBorrowerIssues
        &GetIssuingCharges
        &GetIssuingRule
        &GetBranchBorrowerCircRule
        &GetBranchItemRule
        &GetBiblioIssues
        &AnonymiseIssueHistory
    );

    # subs to deal with returns
    push @EXPORT, qw(
        &AddReturn
        &FixAccountForLostAndReturned
    );

    # subs to deal with transfers
    push @EXPORT, qw(
        &transferbook
        &GetTransfers
        &GetTransfersFromTo
        &updateWrongTransfer
        &DeleteTransfer
                &IsBranchTransferAllowed
                &CreateBranchTransferLimit
                &DeleteBranchTransferLimits
	);
}

=head1 NAME

C4::Circulation - Koha circulation module

=head1 SYNOPSIS

use C4::Circulation;

=head1 DESCRIPTION

The functions in this module deal with circulation, issues, and
returns, as well as general information about the library.
Also deals with stocktaking.

=head1 FUNCTIONS

=head2 barcodedecode

=head3 $str = &barcodedecode(
   barcode           => $barcode, 
  [str               => $barcode], # synonymn for barcode
  [filter            => $filter],
  [prefix            => $prefix],
  [itembarcodeprefix => $prefix],  # synonymn for prefix
  [branchcode        => $branchcode],
);

=over 4

=item Generic filter function for barcode string.
Called on every circ if either System Pref B<itemBarcodeInputFilter> or B<itembarcodelength> is set,
applying one or both modifications as appropriate.

Will do some manipulation of the barcode for systems that deliver a barcode
to circulation.pl that differs from the barcode stored for the item.
For proper functioning of this filter, calling the function on the 
correct barcode string (items.barcode) should return an unaltered barcode.

Per branch barcode prefixes are inserted AFTER the filter function is applied
to fix the barcode at branches.itembarcodelength characters IFF
C<C4::Context->preference('itembarcodelength')> exists and is longer than C<length($barcode)>.

The optional $filter argument is to allow for testing or explicit
behavior that ignores the System Pref.  Valid values are the same as the
System Pref options.

=back

=cut

# FIXME -- the &decode fcn below should be wrapped into this one.
# FIXME -- these plugins should be moved out of Circulation.pm
#
sub barcodedecode 
{
   my %g = @_;
   $g{barcode} ||= $g{str} || return '';
   $g{filter}    = C4::Context->preference('itemBarcodeInputFilter') unless $g{filter};

   my $filter_dispatch = {
        'whitespace' => sub {
                            $g{barcode} =~ s/\s//g;
                            return $g{barcode};
                        },
        'trim' => sub { $g{barcode} =~ s/^\s+|\s+$//g; return $g{barcode}},
        'T-prefix'  =>  sub {
                            if ($g{barcode} =~ /^[Tt]\D*(\d+)/) {
                                my $t = $1;
                                ($t) = $t =~ /(\d)$/ if length($t) < 7;
                                return sprintf("T%07d", $t);
                            } else {
                                return $g{barcode};
                            }
                         },
         'cuecat'   =>  sub {
                             chomp($g{barcode});
                            my @fields = split( /\./, $g{barcode} );
                            my @results = map( decode($_), @fields[ 1 .. $#fields ] );
                            if ( $#results == 2 ) {
                                return $results[2];
                            } else {
                                return $g{barcode};
                            }
                        },
    };
    my $filtered = ($g{filter} && exists($filter_dispatch->{$g{filter}})) 
    ? $filter_dispatch->{$g{filter}}() : $g{barcode};

    ## handle negative numbers
    my $testnum = sprintf("%d",$filtered);
    if (($testnum == $filtered) && $filtered <0) {
       return $filtered;
    }
    
    ## pull it out for running on commandline, esp. *.t
    my %userenv    = %{C4::Context->userenv || {}};
    my $branchcode = $g{branchcode} || $userenv{branch}  || '_TEST';
    my $bclen      = $branchcode eq '_TEST'? length($filtered) 
    : C4::Context->preference('itembarcodelength');
    if($bclen && (length($filtered) < $bclen)) {
        my $prefix = $g{prefix} || $g{itembarcodeprefix} || '';
        if ($prefix) {
            # do nothing
        }
        elsif ($branchcode) {
            $prefix ||= $branchcode eq '_TEST' ? 12345 
            : GetBranchDetail($branchcode)->{'itembarcodeprefix'};
            $prefix ||= '';
        }
        ## relax this
        #else {
        #    die "No library set and/or no branchcode passed to barcodedecode()";
        #}
        #######
        my $padding = C4::Context->preference('itembarcodelength') - length($prefix) - length($filtered);
        $filtered = $prefix . '0' x $padding . $filtered if ($padding >= 0);
    }
    return $filtered || $g{barcode};
}

## not exported
## handle partial barcode strings, possibly multiple branches leading to result
## of multiple partials with same significant digits but different prefixes.
## Unfortunately, this sub goes here b/c we don't want Items.pm to call Circulation.pm
## backwards.
sub GetItemnumbersFromBarcodeStr
{
   my $str = shift;
   my @all = ();
   my $dbh = C4::Context->dbh;
   my $sth;

   unless(C4::Context->preference('itembarcodelength')) {
      push @all, $str;
   }
   else {
      $sth = $dbh->prepare('SELECT branchcode,itembarcodeprefix FROM branches');
      $sth->execute();
      while (my $row = $sth->fetchrow_hashref()) {
         ## relax this
         #die "No itembarcodeprefix set for branch $$row{branchcode} in table branches"
         #   unless $$row{itembarcodeprefix};
         ######
         my $barcode = barcodedecode(
            barcode  => $str,
            prefix   => $$row{itembarcodeprefix},
         );
         push @all, $barcode;
      }
   }
   return [] unless @all;
   my $sql = sprintf("
         SELECT itemnumber,barcode 
           FROM items
          WHERE barcode IN (%s)",
         join(',',map{'?'}@all)
      )
   ;
   $sth = $dbh->prepare($sql);
   $sth->execute(@all);
   undef(@all);
   while(my $row = $sth->fetchrow_hashref()) { push @all, $row; }
   return \@all // [];
}

=head2 decode

=head3 $str = &decode($chunk);

=over 4

=item Decodes a segment of a string emitted by a CueCat barcode scanner and
returns it.

FIXME: Should be replaced with Barcode::Cuecat from CPAN
or Javascript based decoding on the client side.

=back

=cut

sub decode {
    my ($encoded) = @_;
    my $seq =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-';
    my @s = map { index( $seq, $_ ); } split( //, $encoded );
    my $l = ( $#s + 1 ) % 4;
    if ($l) {
        if ( $l == 1 ) {
            # warn "Error: Cuecat decode parsing failed!";
            return;
        }
        $l = 4 - $l;
        $#s += $l;
    }
    my $r = '';
    while ( $#s >= 0 ) {
        my $n = ( ( $s[0] << 6 | $s[1] ) << 6 | $s[2] ) << 6 | $s[3];
        $r .=
            chr( ( $n >> 16 ) ^ 67 )
         .chr( ( $n >> 8 & 255 ) ^ 67 )
         .chr( ( $n & 255 ) ^ 67 );
        @s = @s[ 4 .. $#s ];
    }
    $r = substr( $r, 0, length($r) - $l );
    return $r;
}

=head2 transferbook

($dotransfer, $messages, $iteminformation, $itemnumber) = &transferbook($newbranch, $barcode, $ignore_reserves);

Transfers an item to a new branch. If the item is currently on loan, it is automatically returned before the actual transfer.

C<$newbranch> is the code for the branch to which the item should be transferred.

C<$barcode> is the barcode of the item to be transferred.

If C<$ignore_reserves> is true, C<&transferbook> ignores reserves.
Otherwise, if an item is reserved, the transfer fails.

Returns three values:

=head3 $dotransfer 

is true if the transfer was successful.

=head3 $messages

is a reference-to-hash which may have any of the following keys:

=over 4

=item C<PendingTransfer>

Item already has a pending transfer; cannot do a parallel transfer at the same time.
Message returns a hashref of tobranch, frombranch, and datesent.

=item C<BadBarcode>

There is no item in the catalog with the given barcode. The value is C<$barcode>.

=item C<IsPermanent>

The item's home branch is permanent. This doesn't prevent the item from being transferred, though. The value is the code of the item's home branch.

=item C<DestinationEqualsHolding>

The item is already at the branch to which it is being transferred. The transfer is nonetheless considered to have failed. The value should be ignored.

=item C<WasReturned>

The item was on loan, and C<&transferbook> automatically returned it before transferring it. The value is the borrower number of the patron who had the item.

=item C<ResFound>

The item was reserved. The value is a reference-to-hash whose keys are fields from the reserves table of the Koha database, and C<biblioitemnumber>. It also has the key C<ResFound>, whose value is either C<Waiting> or C<Reserved>.

=item C<WasTransferred>

The item was eligible to be transferred. Barring problems communicating with the 
database, the transfer should indeed have succeeded. The value should be ignored.

=back

=cut

sub transferbook {
    my ( $tbr, $barcode, $ignoreRs ) = @_;
    my $messages;
    my $dotransfer = 1;
    my $branches   = GetBranches();
    my $itemnumber = GetItemnumberFromBarcode( $barcode );
    my $issue      = GetItemIssue($itemnumber);
    my $biblio     = GetBiblioFromItemNumber($itemnumber);

    # bad barcode..
    if ( not $itemnumber ) {
        $messages->{'BadBarcode'} = $barcode;
        $dotransfer = 0;
    }

    # get branches of book...
    my $hbr = $biblio->{'homebranch'};
    my $fbr = $biblio->{'holdingbranch'};
    if ($fbr ~~ $tbr) {
       $messages->{'SameBranch'} = $tbr;
       $dotransfer = 0;
    }

    # if using Branch Transfer Limits
    if ( C4::Context->preference("UseBranchTransferLimits") == 1 ) {
        if ( C4::Context->preference("item-level_itypes") && C4::Context->preference("BranchTransferLimitsType") eq 'itemtype' ) {
            if ( ! IsBranchTransferAllowed( $tbr, $fbr, $biblio->{'itype'} ) ) {
                $messages->{'NotAllowed'} = $tbr . "::" . $biblio->{'itype'};
                $dotransfer = 0;
            }
        } elsif ( ! IsBranchTransferAllowed( $tbr, $fbr, $biblio->{ C4::Context->preference("BranchTransferLimitsType") } ) ) {
            $messages->{'NotAllowed'} = $tbr . "::" . $biblio->{ C4::Context->preference("BranchTransferLimitsType") };
            $dotransfer = 0;
        }
    }

    # if is permanent...
    if ( $hbr && $branches->{$hbr}->{'PE'} ) {
        $messages->{'IsPermanent'} = $hbr;
        $dotransfer = 0;
    }

    # can't transfer book if is already there....
    if ( $fbr eq $tbr ) {
        $messages->{'DestinationEqualsHolding'} = 1;
        $dotransfer = 0;
    }

    # check if it is still issued to someone, return it...
    if ($issue->{borrowernumber}) {
        AddReturn( $barcode, $fbr );
        $messages->{'WasReturned'} = $issue;
    }

    ## huh? -hQ
    # find reserves.....
    # That'll save a database query.
    my ( $resfound, $resrec ) =
      C4::Reserves::CheckReserves( $itemnumber );
    if ( $resfound and not $ignoreRs ) {
        $resrec->{'ResFound'} = $resfound;

        #         $messages->{'ResFound'} = $resrec;
        $dotransfer = 1;
    }

    ## dupecheck: prevent parallel transfers.
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare('
      SELECT frombranch,tobranch,datesent
        FROM branchtransfers
       WHERE itemnumber  = ?
         AND datearrived IS NULL');
    $sth->execute($itemnumber);
    my %bt = %{$sth->fetchrow_hashref() // {}};
    if (%bt) {
       $dotransfer = 0;
       $messages->{PendingTransfer} = \%bt;
    }

    #actually do the transfer....
    if ($dotransfer) {
        ModItemTransfer( $itemnumber, $fbr, $tbr );

        # don't need to update MARC anymore, we do it in batch now
        $messages->{'WasTransfered'} = 1;
        C4::Reserves::RmFromHoldsQueue(itemnumber=>$itemnumber);
    }
    ModDateLastSeen( $itemnumber );
    return ( $dotransfer, $messages, $biblio, $itemnumber );
}


sub TooMany {
    my $borrower     = shift;
    my $biblionumber = shift;
    my $item         = shift;
    my $cat_borrower    = $borrower->{'categorycode'};
    my $dbh             = C4::Context->dbh;
    # Get which branchcode we need
    my $userenv;
    my $currBranch;

    if (C4::Context->userenv) { $userenv = C4::Context->userenv }
    if ($userenv) { $currBranch = $userenv->{branch}; }
    else          { $currBranch = $borrower->{branchcode} }
    my $branch = GetCircControlBranch(
      pickup_branch      => $currBranch,
      item_homebranch    => $item->{homebranch},
      item_holdingbranch => $item->{holdingbranch},
      borrower_branch    => $borrower->{branchcode},
    );
    my $type = (C4::Context->preference('item-level_itypes')) 
            ? $item->{'itype'}         # item-level
            : $item->{'itemtype'};     # biblio-level
 
    # given branch, patron category, and item type, determine
    # applicable issuing rule
    my $issuing_rule = GetIssuingRule($cat_borrower, $type, $branch);

    # if a rule is found and has a loan limit set, count
    # how many loans the patron already has that meet that
    # rule
    if (defined($issuing_rule) and defined($issuing_rule->{'maxissueqty'})) {
        my @bind_params;
        my $count_query = "SELECT COUNT(*) FROM issues
                           JOIN items USING (itemnumber) ";

        my $rule_itemtype = $issuing_rule->{itemtype};
        if ($rule_itemtype eq "*") {
            # matching rule has the default item type, so count only
            # those existing loans that don't fall under a more
            # specific rule
            if (C4::Context->preference('item-level_itypes')) {
                $count_query .= " WHERE items.itype NOT IN (
                                    SELECT itemtype FROM issuingrules
                                    WHERE branchcode = ?
                                    AND   (categorycode = ? OR categorycode = ?)
                                    AND   itemtype <> '*'
                                  ) ";
            } else { 
                $count_query .= " JOIN  biblioitems USING (biblionumber) 
                                  WHERE biblioitems.itemtype NOT IN (
                                    SELECT itemtype FROM issuingrules
                                    WHERE branchcode = ?
                                    AND   (categorycode = ? OR categorycode = ?)
                                    AND   itemtype <> '*'
                                  ) ";
            }
            push @bind_params, $issuing_rule->{branchcode};
            push @bind_params, $issuing_rule->{categorycode};
            push @bind_params, $cat_borrower;
        } else {
            # rule has specific item type, so count loans of that
            # specific item type
            if (C4::Context->preference('item-level_itypes')) {
                $count_query .= " WHERE items.itype = ? ";
            } else { 
                $count_query .= " JOIN  biblioitems USING (biblionumber) 
                                  WHERE biblioitems.itemtype= ? ";
            }
            push @bind_params, $type;
        }

        $count_query .= " AND borrowernumber = ? ";
        push @bind_params, $borrower->{'borrowernumber'};
        my $rule_branch = $issuing_rule->{branchcode};
        if ($rule_branch ne "*") {
            if (C4::Context->preference('CircControl') eq 'PickupLibrary') {
                $count_query .= " AND issues.branchcode = ? ";
                push @bind_params, $branch;
            } elsif (C4::Context->preference('CircControl') eq 'PatronLibrary') {
                ; # if branch is the patron's home branch, then count all loans by patron
            } else {
                $count_query .= " AND items.homebranch = ? ";
                push @bind_params, $branch;
            }
        }

        my $count_sth = $dbh->prepare($count_query);
        $count_sth->execute(@bind_params);
        my ($current_loan_count) = $count_sth->fetchrow_array;

        my $max_loans_allowed = $issuing_rule->{'maxissueqty'};
        if ($current_loan_count >= $max_loans_allowed) {
            return "$current_loan_count / $max_loans_allowed";
        }
    }

    # Now count total loans against the limit for the branch
    my $branch_borrower_circ_rule = GetBranchBorrowerCircRule($branch, $cat_borrower);
    if (defined($branch_borrower_circ_rule->{maxissueqty})) {
        my @bind_params = ();
        my $branch_count_query = "SELECT COUNT(*) FROM issues 
                                  JOIN items USING (itemnumber)
                                  WHERE borrowernumber = ? ";
        push @bind_params, $borrower->{borrowernumber};

        if (C4::Context->preference('CircControl') eq 'PickupLibrary') {
            $branch_count_query .= " AND issues.branchcode = ? ";
            push @bind_params, $branch;
        } elsif (C4::Context->preference('CircControl') eq 'PatronLibrary') {
            ; # if branch is the patron's home branch, then count all loans by patron
        } else {
            $branch_count_query .= " AND items.homebranch = ? ";
            push @bind_params, $branch;
        }
        my $branch_count_sth = $dbh->prepare($branch_count_query);
        $branch_count_sth->execute(@bind_params);
        my ($current_loan_count) = $branch_count_sth->fetchrow_array;

        my $max_loans_allowed = $branch_borrower_circ_rule->{maxissueqty};
        if ($current_loan_count >= $max_loans_allowed) {
            return "$current_loan_count / $max_loans_allowed";
        }
    }

    # OK, the patron can issue !!!
    return;
}

=head2 itemissues

  @issues = &itemissues($biblioitemnumber, $biblio);

Looks up information about who has borrowed the bookZ<>(s) with the
given biblioitemnumber.

C<$biblio> is ignored.

C<&itemissues> returns an array of references-to-hash. The keys
include the fields from the C<items> table in the Koha database.
Additional keys include:

=over 4

=item C<date_due>

If the item is currently on loan, this gives the due date.

If the item is not on loan, then this is either "Available" or
"Cancelled", if the item has been withdrawn.

=item C<card>

If the item is currently on loan, this gives the card number of the
patron who currently has the item.

=item C<timestamp0>, C<timestamp1>, C<timestamp2>

These give the timestamp for the last three times the item was
borrowed.

=item C<card0>, C<card1>, C<card2>

The card number of the last three patrons who borrowed this item.

=item C<borrower0>, C<borrower1>, C<borrower2>

The borrower number of the last three patrons who borrowed this item.

=back

=cut

#'
sub itemissues {
    my ( $bibitem, $biblio ) = @_;
    my $dbh = C4::Context->dbh;
    my $sth =
      $dbh->prepare("Select * from items where items.biblioitemnumber = ?")
      || die $dbh->errstr;
    my @results;

    $sth->execute($bibitem) || die $sth->errstr;

    while ( my $data = $sth->fetchrow_hashref ) {

        # Find out who currently has this item.
        # FIXME - Wouldn't it be better to do this as a left join of
        # some sort? Currently, this code assumes that if
        # fetchrow_hashref() fails, then the book is on the shelf.
        # fetchrow_hashref() can fail for any number of reasons (e.g.,
        # database server crash), not just because no items match the
        # search criteria.
        my $sth2 = $dbh->prepare(
            "SELECT * FROM issues
                LEFT JOIN borrowers ON issues.borrowernumber = borrowers.borrowernumber
                WHERE itemnumber = ?
            "
        );

        $sth2->execute( $data->{'itemnumber'} );
        if ( my $data2 = $sth2->fetchrow_hashref ) {
            $data->{'date_due'} = $data2->{'date_due'};
            $data->{'card'}     = $data2->{'cardnumber'};
            $data->{'borrower'} = $data2->{'borrowernumber'};
        }
        else {
            $data->{'date_due'} = ($data->{'wthdrawn'} eq '1') ? 'Cancelled' : 'Available';
        }

        $sth2->finish;

        # Find the last 3 people who borrowed this item.  while() loop controls <3
        $sth2 = $dbh->prepare(
            "SELECT * FROM old_issues
                LEFT JOIN borrowers ON  issues.borrowernumber = borrowers.borrowernumber
                WHERE itemnumber = ?
                LIMIT 3
                ORDER BY returndate DESC,timestamp DESC"
        );

        $sth2->execute( $data->{'itemnumber'} );
        my $i2 = 0;
        while(my $data2 = $sth2->fetchrow_hashref()) {
            $data->{"timestamp$i2"} = $data2->{'timestamp'};
            $data->{"card$i2"}      = $data2->{'cardnumber'};
            $data->{"borrower$i2"}  = $data2->{'borrowernumber'};
            $i2++;
        }
        push @results, $data;
    }

    $sth->finish;
    return (@results);
}

=head2 CanBookBeIssued

Check if a book can be issued.

( $issuingimpossible, $needsconfirmation ) =  CanBookBeIssued( $borrower, $barcode, $duedatespec, $inprocess );

C<$issuingimpossible> and C<$needsconfirmation> are some hashref.

=over 4

=item C<$borrower> hash with borrower informations (from GetMemberDetails)

=item C<$barcode> is the bar code of the book being issued.

=item C<$duedatespec> is a C4::Dates object.

=item C<$inprocess>

=back

Returns :

=over 4

=item C<$issuingimpossible> a reference to a hash. It contains reasons why issuing is impossible.
Possible values are :

=back

=head3 INVALID_DATE 

sticky due date is invalid

=head3 GNA

borrower gone with no address

=head3 CARD_LOST

borrower declared it's card lost

=head3 DEBARRED

borrower debarred

=head3 UNKNOWN_BARCODE

barcode unknown

=head3 NOT_FOR_LOAN

item is not for loan

=head3 WTHDRAWN

item withdrawn.

=head3 RESTRICTED

item is restricted (set by ??)

C<$issuingimpossible> a reference to a hash. It contains reasons why issuing is impossible.
Possible values are :

=head3 DEBT

borrower has debts.

=head3 RENEW_ISSUE

renewing, not issuing

=head3 ISSUED_TO_ANOTHER

issued to someone else.

=head3 RESERVED

reserved for someone else.

=head3 INVALID_DATE

sticky due date is invalid

=head3 TOO_MANY

if the borrower borrows to much things

=cut

sub CanBookBeIssued {
    my ( $borrower, $barcode, $duedate, $inprocess ) = @_;
    my %needsconfirmation;    # filled with problems that needs confirmations
    my %issuingimpossible;    # filled with problems that causes the issue to be IMPOSSIBLE
    my $item = GetItem(GetItemnumberFromBarcode( $barcode ));
    my $issue = GetItemIssue($item->{itemnumber});
    my $biblioitem = GetBiblioItemData($item->{biblioitemnumber});
    $item->{'itemtype'}=$item->{'itype'}; 
    my $dbh             = C4::Context->dbh;

    # MANDATORY CHECKS - unless item exists, nothing else matters
    unless ( $item->{barcode} ) {
        $issuingimpossible{UNKNOWN_BARCODE} = 1;
    }
    return ( \%issuingimpossible, \%needsconfirmation ) if %issuingimpossible;

    #
    # DUE DATE is OK ? -- should already have checked.
    #
    my $useBranch;
    if (C4::Context->userenv) { $useBranch = C4::Context->userenv->{branch} }
    unless ( $duedate ) {
        my $issuedate = C4::Dates->new()->output('iso');
        my $branch = GetCircControlBranch(
            pickup_branch      => $issue->{issuingbranch} // $issue->{branchcode} // $useBranch // $item->{homebranch},
            item_homebranch    => $item->{homebranch},
            item_holdingbranch => $item->{holdingbranch},
            borrower_branch    => $borrower->{branchcode},
        );

        my $itype = ( C4::Context->preference('item-level_itypes') ) ? $item->{'itype'} : $biblioitem->{'itemtype'};
        my $loanlength = GetLoanLength( $borrower->{'categorycode'}, $itype, $branch );
        $duedate = CalcDateDue( C4::Dates->new( $issuedate, 'iso' ), $loanlength, $branch, $borrower );

        # Offline circ calls AddIssue directly, doesn't run through here
        #  So issuingimpossible should be ok.
    }
    my $skip_duedate_check = C4::Context->preference('AllowDueDateInPast');
    if (!$skip_duedate_check) {
        unless ( $duedate && $duedate->output('iso') ge C4::Dates->today('iso') ) {
            $issuingimpossible{INVALID_DATE} = $duedate->output('syspref');
        }
    }

    #
    # BORROWER STATUS
    #
    if ( $borrower->{'category_type'} eq 'X' && (  $item->{barcode}  )) { 
        # stats only borrower -- add entry to statistics table, and return issuingimpossible{STATS} = 1  .
        &UpdateStats($useBranch // $item->{homebranch},'localuse','','',$item->{'itemnumber'},$item->{'itemtype'},$borrower->{'borrowernumber'});
        return( { STATS => 1 }, {});
    }
    if ( $borrower->{flags}->{GNA} ) {
        $issuingimpossible{GNA} = 1;
    }
    if ( $borrower->{flags}->{'LOST'} ) {
        $issuingimpossible{CARD_LOST} = 1;
    }
    if ( $borrower->{flags}->{'DBARRED'} ) {
        $issuingimpossible{DEBARRED} = 1;
    }
    if ( $borrower->{'dateexpiry'} eq '0000-00-00') {
        $issuingimpossible{EXPIRED} = 1;
    } else {
        my @expirydate=  split /-/,$borrower->{'dateexpiry'};
        if($expirydate[0]==0 || $expirydate[1]==0|| $expirydate[2]==0 ||
            Date_to_Days(Today) > Date_to_Days( @expirydate )) {
            $issuingimpossible{EXPIRED} = 1;                                   
        }
    }
    #
    # BORROWER STATUS
    #

    # DEBTS
    my $amount = C4::Accounts::MemberAllAccounts( 
      borrowernumber => $borrower->{'borrowernumber'}, 
      date           => '' && $duedate->output('iso'),
      total_only     => 1,
    ) || 0;
    my $cat = C4::Members::GetCategoryInfo($$borrower{categorycode}) // {};
    $$cat{circ_block_threshold} //= 0;
    if ( C4::Context->preference("IssuingInProcess") ) {
        my $amountlimit = ($$cat{circ_block_threshold}>0)? $$cat{circ_block_threshold} : 0;

        if ($amountlimit) {
           if ( $amount > $amountlimit && !$inprocess ) {
               $issuingimpossible{DEBT} = sprintf( "%.2f", $amount );
           }
           elsif ( $amount > 0 && $amount <= $amountlimit && !$inprocess && !C4::Context->preference('WarnOnlyOnMaxFine') ) {
               $needsconfirmation{DEBT} = sprintf( "%.2f", $amount );
           }
        }
    }
    else {
        my $max_fine = 0;
        if ( C4::Context->preference('WarnOnlyOnMaxFine')) {
            $max_fine = $$cat{circ_block_threshold};
        }

        if ($max_fine) {
           if ( $amount > $max_fine ) {
               $needsconfirmation{DEBT} = sprintf( "%.2f", $amount );
           }
        }
    }

    #
    # JB34 CHECKS IF BORROWERS DONT HAVE ISSUE TOO MANY BOOKS
    #
    my $toomany = TooMany( $borrower, $item->{biblionumber}, $item );
    # if TooMany return / 0, then the user has no permission to check out this book
    if ($toomany && $toomany =~ /\/ 0/) {
        $needsconfirmation{PATRON_CANT} = 1;
    } else {
        $needsconfirmation{TOO_MANY} = $toomany if $toomany;
    }

    #
    # ITEM CHECKING
    #
    if (   $item->{'notforloan'}
        && $item->{'notforloan'} != 0 )
    {
        if(!C4::Context->preference("AllowNotForLoanOverride")){
            $issuingimpossible{NOT_FOR_LOAN} = 1;
        }else{
            $needsconfirmation{NOT_FOR_LOAN_FORCING} = 1;
        }
    }
    elsif ( !$item->{'notforloan'} ){
        # we have to check itemtypes.notforloan also
        #if (C4::Context->preference('item-level_itypes')){
            # this should probably be a subroutine
            my $sth = $dbh->prepare("SELECT notforloan FROM itemtypes WHERE itemtype = ?");
            $sth->execute($item->{'itemtype'});
            my $notforloan=$sth->fetchrow_hashref();
            $sth->finish();
            if ($notforloan->{'notforloan'}) {
                if (!C4::Context->preference("AllowNotForLoanOverride")) {
                    $issuingimpossible{NOT_FOR_LOAN} = 1;
                } else {
                    $needsconfirmation{NOT_FOR_LOAN_FORCING} = 1;
                }
            }
        #}
        #elsif ($biblioitem->{'notforloan'} == 1){
        if (!$notforloan && $$biblioitem{notforloan}==1) {
            if (!C4::Context->preference("AllowNotForLoanOverride")) {
                $issuingimpossible{NOT_FOR_LOAN} = 1;
            } else {
                $needsconfirmation{NOT_FOR_LOAN_FORCING} = 1;
            }
        }
    }
    if ( $item->{'wthdrawn'} && $item->{'wthdrawn'} == 1 )
    {
        $issuingimpossible{WTHDRAWN} = 1;
    }
    if (   $item->{'restricted'}
        && $item->{'restricted'} == 1 )
    {
        $issuingimpossible{RESTRICTED} = 1;
    }
    if ( C4::Context->preference("IndependantBranches") ) {
        my $userenv = C4::Context->userenv;
        if ( ($userenv) && ( $userenv->{flags} % 2 != 1 ) ) {
            $issuingimpossible{NOTSAMEBRANCH} = 1
              if ( $item->{C4::Context->preference("HomeOrHoldingBranch")} ne $userenv->{branch} );
        }
    }

    #
    # CHECK IF BOOK ALREADY ISSUED TO THIS BORROWER
    #
    if ( $issue->{borrowernumber} && $issue->{borrowernumber} eq $borrower->{'borrowernumber'} )
    {
        #Already issued to current borrower. Ask whether the loan should
        # be renewed.
        my ($CanBookBeRenewed,$renewerror) = CanBookBeRenewed(
            $borrower->{'borrowernumber'},
            $item->{'itemnumber'}
        );
        if ( $CanBookBeRenewed == 0 ) {    # no more renewals allowed
            $issuingimpossible{NO_MORE_RENEWALS} = 1;
        }
        else {
            $needsconfirmation{RENEW_ISSUE} = 1;
        }
    }
    elsif ($issue->{borrowernumber}) {

        # issued to someone else
        my $currborinfo =    C4::Members::GetMemberDetails( $issue->{borrowernumber} );

#        warn "=>.$currborinfo->{'firstname'} $currborinfo->{'surname'} ($currborinfo->{'cardnumber'})";
        $needsconfirmation{ISSUED_TO_ANOTHER} =
"$currborinfo->{'reservedate'} : $currborinfo->{'firstname'} $currborinfo->{'surname'} ($currborinfo->{'cardnumber'})";
    }

   # See if the item is on reserve.
   RESERVE: {
      my @prompts = split(/\|/,C4::Context->preference('reservesNeedConfirmationOnCheckout'));
      unless (@prompts) { @prompts = qw(otherBibItem patronNotReservist_holdWaiting) }
      last RESERVE if ('noPrompts' ~~ @prompts);
      my ($restype,$res) = C4::Reserves::CheckReserves( $item->{'itemnumber'},$$item{biblionumber},$$borrower{borrowernumber});
      last RESERVE unless $res;
      my $suffix = ($$res{found} ~~ 'W')? 'WAITING' : 'PENDING';
      if ($$borrower{borrowernumber} ~~ $$res{borrowernumber}) {
         last unless ('otherBibItem' ~~ @prompts);
         if (($$item{biblionumber} == $$res{biblionumber}) && ($$res{itemnumber} ne $$item{itemnumber})) {
            $needsconfirmation{"RESERVE_SAMEBOR_DIFFBIBITEM_$suffix"} = $res;
         }
      }
      else {
         if (  (($suffix eq 'WAITING') && ('patronNotReservist_holdWaiting' ~~ @prompts))
            || (($suffix eq 'PENDING') && ('patronNotReservist_holdPending' ~~ @prompts)) ) { 
            $needsconfirmation{"RESERVE_DIFFBOR_$suffix"} = $res;
         }
      }
      ;
   }

   return ( \%issuingimpossible, \%needsconfirmation );
}

=head2 AddIssue

Issue a book. Does no check, they are done in CanBookBeIssued. If we reach this sub, it means the user confirmed if needed.

&AddIssue(\%args)

=over 4

=item C<$borrower> is a hash with borrower informations (from GetMemberDetails).

=item C<$barcode> is the barcode of the item being issued.

=item C<$datedueObj> is a C4::Dates object for the max date of return, i.e. the date due (optional).
Calculated if empty.

=item C<$howReserve> is 'cancel','fill', or 'requeue' (optional) for reconciling a reserve that belongs
to another patron other than the checkout patron.

=item C<$cancelReserve> is 1 to override and cancel any pending reserves for the item (optional); used
if you don't want to set $howReserve.

=item C<$requeueReserve> is 1 to send reserve back to priority 1 in the bib's existing holds (optional); used
if you don't want to set $howReserve.

=item C<$issuedate> is the date to issue the item in iso (YYYY-MM-DD) format (optional).
Defaults to today.  Unlike C<$datedue>, NOT a C4::Dates object, unfortunately.

AddIssue does the following things :

  - step 01: check that there is a borrowernumber & a barcode provided
  - check for RENEWAL (book issued & being issued to the same patron)
      - renewal YES = Calculate Charge & renew
      - renewal NO  =
          * BOOK ACTUALLY ISSUED ? do a return if book is actually issued (but to someone else)
          * RESERVE PLACED ?
              - fill reserve if reserve to this patron or authorised
              - cancel reserve or not, otherwise
          * ISSUE THE BOOK

=back

=cut

sub AddIssue {
   my %g = @_;
   my $isRenewal     = 0;
   my $borrower      = $g{borrower}       // {};
   my $barcode       = $g{barcode}        // '';
   my $datedueObj    = $g{datedueObj};
   my $cancelReserve = $g{cancelReserve}  || 0;
   my $requeueReserve= $g{requeueReserve} || 0;
   my $fillReserve   = $g{fillReserve}    || 0;
   my $howReserve    = $g{howReserve}     || '';
   my $issuedate     = $g{issuedate}      // '';
   my $sipmode       = $g{sipmode}        || 0;
   unless($howReserve) {
      if    ($cancelReserve)  { $howReserve = 'cancel' }
      elsif ($requeueReserve) { $howReserve = 'requeue'}
      elsif ($fillReserve)    { $howReserve = 'fill'   }
   }
  
   my $datedue;
   my($charge,$itemtype);
   my $sth;
   my $dbh = C4::Context->dbh;
   my $barcodecheck=CheckValidBarcode($barcode);
   
   return unless ($borrower and $barcode and $barcodecheck);
		
   unless ($issuedate) { # $issuedate defaults to today.
      $issuedate = strftime( "%Y-%m-%d", localtime );
      # TODO: for hourly circ, this will need to be a C4::Dates object
      # and all calls to AddIssue including issuedate will need to pass a Dates object.
   }
   if (ref($datedueObj)) { $datedue = $datedueObj->output('iso') }
    
   my $item = GetItem('', $barcode) or return undef;  # if we don't get an Item, abort.
   my $actualissue = GetItemIssue( $item->{itemnumber});
   my $currBranch = C4::Context->userenv->{branch};
   my $branch = GetCircControlBranch(
      pickup_branch      => $currBranch,
      item_homebranch    => $item->{homebranch},
      item_holdingbranch => $item->{holdingbranch},
      borrower_branch    => $borrower->{branchcode},
   );
   my $biblio = GetBiblioFromItemNumber($item->{itemnumber});
        
   if (($actualissue->{borrowernumber} // '') eq $borrower->{'borrowernumber'}) {
            $datedue = AddRenewal(
               borrower       => $borrower,
               item           => $item,
               issue          => $actualissue,
               datedueObj     => $datedueObj,
               issuedate      => $issuedate,# renewal date
               exemptfine     => $g{exemptfine},
            );
      return $datedue;
   }
   
   # it's NOT a renewal
   if ( $actualissue->{borrowernumber}) {
      # This book is currently on loan, but not to the person
      # who wants to borrow it now. mark it returned before issuing to the new borrower
      AddReturn(
         $item->{'barcode'},
         C4::Context->userenv->{'branch'}
      );
   }

   my($restype,$res) = C4::Reserves::CheckReserves($item->{'itemnumber'},$$item{biblionumber},$$borrower{borrowernumber});
   ## value(s) of $restype:
   ##    'Reserved'
   ##    'Waiting'
   ##    empty or undef or otherwise false (zero, I believe)
   if ($res) {
      my $resbor = $res->{'borrowernumber'};
      if (($resbor eq $borrower->{'borrowernumber'}) || ($howReserve eq 'fill')) {
         if ($howReserve eq 'requeue') {
            if ($$res{priority} == 0) {
               C4::Reserves::ModReserve(1,$res->{'biblionumber'},
                            $res->{'borrowernumber'},
                            $res->{'branchcode'},                                 
                            undef,     ## $res->{'itemnumber'},
                            $res->{'reservenumber'});
            } # else ignore numbered priority: actual requeue as-is
         }
         else {
            C4::Reserves::FillReserve($res,$$item{itemnumber});
         }
      }
      ## cancels top reserve regardless Waiting or priority 1 or such
      elsif ($howReserve eq 'cancel') {
         C4::Reserves::CancelReserve($res->{'reservenumber'});
      }
      elsif (($$res{found} ~~ 'W') || ($howReserve eq 'requeue')) {
         # The item is on reserve and waiting, but has been
         # reserved by some other patron.
         ## FIXME: requeue as bib-level hold is temporary until we get
         ## a permanent fix for retaining bib- or item-level hold
         if (($$res{priority}==0) || ($$res{found} ~~ 'W')) {
            C4::Reserves::ModReserve(1,$res->{'biblionumber'},
                         $res->{'borrowernumber'},
                         $res->{'branchcode'},                                 
                         undef,     ## $res->{'itemnumber'},
                         $res->{'reservenumber'});
         }
      }  
   }
   
   ## remove from tmp_holdsqueue and branchtransfers
   C4::Reserves::RmFromHoldsQueue(itemnumber=>$$item{itemnumber});
   DeleteTransfer($$item{itemnumber});

   # Record in the database the fact that the book was issued.
   $sth = $dbh->prepare(
                "INSERT INTO issues 
                    (borrowernumber, itemnumber,issuedate, date_due, branchcode, issuingbranch)
                VALUES (?,?,?,?,?,?)"
   );
   unless ($datedue) {
      my $itype = ( C4::Context->preference('item-level_itypes') ) ? $biblio->{'itype'} : $biblio->{'itemtype'};
      my $loanlength = GetLoanLength( $borrower->{'categorycode'}, $itype, $branch );
      $datedueObj = CalcDateDue( C4::Dates->new( $issuedate, 'iso' ), $loanlength, $branch, $borrower );
      $datedue    = $datedueObj->output('iso');
   }
   $sth->execute(
            $borrower->{'borrowernumber'},      # borrowernumber
            $item->{'itemnumber'},              # itemnumber
            $issuedate,                         # issuedate
            $datedue,                           # date_due
            $currBranch,                        # branchcode: this might change upon renewal
            $currBranch,                        # issuingbranch: this must not change
   );
   $sth->finish;
   if ( C4::Context->preference('ReturnToShelvingCart') ) { ## ReturnToShelvingCart is on, anything issued should be taken off the cart.
      CartToShelf( $item->{'itemnumber'} );
   }
   $item->{'issues'}++;
   ModItem(     { issues           => $item->{'issues'},
                  holdingbranch    => $currBranch, # this might change upon renewal
                  itemlost         => 0,
                  paidfor          => '',
                  datelastborrowed => C4::Dates->new()->output('iso'),
                  onloan           => $datedue,
                }, $item->{'biblionumber'}, $item->{'itemnumber'});
   ModDateLastSeen( $item->{'itemnumber'} );

   # If it costs to borrow this book, charge it to the patron's account.
   ($charge,$itemtype) = _chargeToAccount($$item{itemnumber},$$borrower{borrowernumber},$issuedate);
   $item->{'charge'} = $charge;
   
   # Possibly anonymize
   AnonymisePreviousBorrower($item);

   # Record the fact that this book was issued
   &UpdateStats(
         $currBranch,
         'issue', $charge,
         ($sipmode ? "SIP-$sipmode" : ''), $item->{'itemnumber'},
         $item->{'itype'}, $borrower->{'borrowernumber'}
   );
 
   # Send a checkout slip.
   my $circulation_alert = 'C4::ItemCirculationAlertPreference';
   my %conditions = (
      branchcode   => $branch,
      categorycode => $borrower->{categorycode},
      item_type    => $item->{itype},
      notification => 'CHECKOUT',
   );
   if ($circulation_alert->is_enabled_for(\%conditions)) {
      SendCirculationAlert({
         type     => 'CHECKOUT',
         item     => $item,
         borrower => $borrower,
         branch   => $branch,
      });
   }

    ## handle previously lost
    if (my $lostitem = GetLostItem($$item{itemnumber})) {
        ## whoever last lost this item will get credit that it was found
        _FixAccountNowFound($$borrower{borrowernumber},$lostitem,C4::Dates->new(),0,1);
        C4::LostItems::DeleteLostItem($$lostitem{id});
    }

    logaction("CIRCULATION", "ISSUE", $borrower->{'borrowernumber'}, $biblio->{'biblionumber'})
        if C4::Context->preference("IssueLog");

    return $datedue;    # not necessarily the same as when it came in!
}

sub AnonymisePreviousBorrower {
    my ($item) = @_;

    my $previous = GetOldIssue($item->{itemnumber});
    return if !$previous->{borrowernumber};

    my $borrower = C4::Members::GetMember($previous->{borrowernumber});
    return undef if !$borrower;

    if (   C4::Context->preference('AllowReadingHistoryAnonymizing')
        && $borrower->{disable_reading_history})
    {
        AnonymiseIssueHistory(
            undef, $borrower->{borrowernumber}, $item->{itemnumber});
    }
}

=head2 GetIssuingRule

Get the issuing rule for an itemtype, a borrower type and a branch
Returns a hashref from the issuingrules table.

my $irule = &GetIssuingRule($categorycode, $itemtype, $branchcode)

=cut

sub _seed_irule_cache {
    return C4::Context->dbh->selectall_hashref(
        'SELECT * FROM issuingrules WHERE issuelength IS NOT NULL',
        ['categorycode', 'itemtype', 'branchcode']);
}

sub _clear_irule_cache {
    my $cache = C4::Context->getcache(__PACKAGE__,
                                      {driver => 'RawMemory',
                                      datastore => C4::Context->cachehash});
    $cache->remove('irules');
}

sub GetIssuingRule {
    my ($categorycode, $itemtype, $branchcode) = @_;
    $categorycode //= '*';
    $itemtype //= '*';
    $branchcode //= '*';

    my $cache = C4::Context->getcache(__PACKAGE__,
                                      {driver => 'RawMemory',
                                      datastore => C4::Context->cachehash});

    my $irules = $cache->compute('irules', '5m', \&_seed_irule_cache);
    my $irule = $irules->{$categorycode}{$itemtype}{$branchcode} //
        $irules->{$categorycode}{'*'}{$branchcode} //
        $irules->{'*'}{$itemtype}{$branchcode} //
        $irules->{'*'}{'*'}{$branchcode} //
        $irules->{$categorycode}{$itemtype}{'*'} //
        $irules->{$categorycode}{'*'}{'*'} //
        $irules->{'*'}{$itemtype}{'*'} //
        $irules->{'*'}{'*'}{'*'} //
        undef;

    return $irule;
}

=head2 GetLoanLength

Get loan length for an itemtype, a borrower type and a branch

my $loanlength = &GetLoanLength($categorycode, $itemtype, $branchcode)

=cut

sub GetLoanLength($$$) {
    my ($categorycode, $itemtype, $branchcode) = @_;
    my $loanlength = 21;

    my $irule = GetIssuingRule($categorycode, $itemtype, $branchcode);
    $loanlength = $irule->{issuelength} if defined $irule;

    return $loanlength;
}

=head2 GetBranchBorrowerCircRule

=over 4

my $branch_cat_rule = GetBranchBorrowerCircRule($branchcode, $categorycode);

=back

Retrieves circulation rule attributes that apply to the given
branch and patron category, regardless of item type.  
The return value is a hashref containing the following key:

maxissueqty - maximum number of loans that a
patron of the given category can have at the given
branch.  If the value is undef, no limit.

This will first check for a specific branch and
category match from branch_borrower_circ_rules. 

If no rule is found, it will then check default_branch_circ_rules
(same branch, default category).  If no rule is found,
it will then check default_borrower_circ_rules (default 
branch, same category), then failing that, default_circ_rules
(default branch, default category).

If no rule has been found in the database, it will default to
the buillt in rule:

maxissueqty - undef

C<$branchcode> and C<$categorycode> should contain the
literal branch code and patron category code, respectively - no
wildcards.

=cut

sub GetBranchBorrowerCircRule {
    my $branchcode = shift;
    my $categorycode = shift;

    my $branch_cat_query = "SELECT maxissueqty
                            FROM branch_borrower_circ_rules
                            WHERE branchcode = ?
                            AND   categorycode = ?";
    my $dbh = C4::Context->dbh();
    my $sth = $dbh->prepare($branch_cat_query);
    $sth->execute($branchcode, $categorycode);
    my $result;
    if ($result = $sth->fetchrow_hashref()) {
        return $result;
    }

    # try same branch, default borrower category
    my $branch_query = "SELECT maxissueqty
                        FROM default_branch_circ_rules
                        WHERE branchcode = ?";
    $sth = $dbh->prepare($branch_query);
    $sth->execute($branchcode);
    if ($result = $sth->fetchrow_hashref()) {
        return $result;
    }

    # try default branch, same borrower category
    my $category_query = "SELECT maxissueqty
                          FROM default_borrower_circ_rules
                          WHERE categorycode = ?";
    $sth = $dbh->prepare($category_query);
    $sth->execute($categorycode);
    if ($result = $sth->fetchrow_hashref()) {
        return $result;
    }
  
    # try default branch, default borrower category
    my $default_query = "SELECT maxissueqty
                          FROM default_circ_rules";
    $sth = $dbh->prepare($default_query);
    $sth->execute();
    if ($result = $sth->fetchrow_hashref()) {
        return $result;
    }
    
    # built-in default circulation rule
    return {
        maxissueqty => undef,
    };
}

=head2 GetBranchItemRule

=over 4

my $branch_item_rule = GetBranchItemRule($branchcode, $itemtype);

=back

**DEPRECATED**: Hold policies are now stored in issuingrules.

Retrieves circulation rule attributes that apply to the given
branch and item type, regardless of patron category.

The return value is a hashref containing the following key:

holdallowed => Hold policy for this branch and itemtype. Possible values:
  0: No holds allowed.
  1: Holds allowed only by patrons that have the same homebranch as the item.
  2: Holds allowed from any patron.

This searches branchitemrules in the following order:

  * Same branchcode and itemtype
  * Same branchcode, itemtype '*'
  * branchcode '*', same itemtype
  * branchcode and itemtype '*'

Neither C<$branchcode> nor C<$categorycode> should be '*'.

=cut

sub GetBranchItemRule {
    my ( $branchcode, $itemtype ) = @_;
    my $dbh = C4::Context->dbh();
    my $result = {};

    my @attempts = (
        ['SELECT holdallowed
            FROM branch_item_rules
            WHERE branchcode = ?
              AND itemtype = ?', $branchcode, $itemtype],
        ['SELECT holdallowed
            FROM default_branch_circ_rules
            WHERE branchcode = ?', $branchcode],
        ['SELECT holdallowed
            FROM default_branch_item_rules
            WHERE itemtype = ?', $itemtype],
        ['SELECT holdallowed
            FROM default_circ_rules'],
    );

    foreach my $attempt (@attempts) {
        my ($query, @bind_params) = @{$attempt};

        # Since branch/category and branch/itemtype use the same per-branch
        # defaults tables, we have to check that the key we want is set, not
        # just that a row was returned
        return $result if ( defined( $result->{'holdallowed'} = $dbh->selectrow_array( $query, {}, @bind_params ) ) );
    }
    
    # built-in default circulation rule
    return {
        holdallowed => 2,
    };
}

=head2 AddReturn

($doreturn, $messages, $iteminformation, $borrower) =
    &AddReturn($barcode, $branch, $exemptfine, $dropbox, [$returndate]);

Returns a book.

=over 4

=item C<$barcode> is the bar code of the book being returned.

=item C<$branch> is the code of the branch where the book is being returned.

=item C<$exemptfine> indicates that overdue charges for the item will be
removed.

=item C<$dropbox> indicates that the check-in date is assumed to be
yesterday, or the last non-holiday as defined in C4::Calendar .  If
overdue charges are applied and C<$dropbox> is true, the last charge
will be removed.  This assumes that the fines accrual script has run
for _today_.
                    :w
=item C<$returndate> is only passed if the default return date (i.e. today)
is to be overridden, the date is passed in ISO format

=back

C<&AddReturn> returns a list of four items:

C<$doreturn> is true iff the return succeeded.

C<$messages> is a reference-to-hash giving feedback on the operation.
The keys of the hash are:

=over 4

=item C<BadBarcode>

No item with this barcode exists. The value is C<$barcode>.

=item C<NotIssued>

The book is not currently on loan. The value is C<$barcode>.

=item C<IsPermanent>

The book's home branch is a permanent collection. If you have borrowed
this book, you are not allowed to return it. The value is the code for
the book's home branch.

=item C<wthdrawn>

This book has been withdrawn/cancelled. The value should be ignored.

=item C<Wrongbranch>

This book was returned to the wrong branch.  The value is a hashref
so that C<$messages->{Wrongbranch}->{Wrongbranch}> and C<$messages->{Wrongbranch}->{Rightbranch}>
contain the branchcode of the incorrect and correct return library, respectively.

=item C<ResFound>

The item was reserved. The value is a reference-to-hash whose keys are
fields from the reserves table of the Koha database, and
C<biblioitemnumber>. It also has the key C<ResFound>, whose value is
either C<Waiting>, C<Reserved>, or 0.

=back

C<$iteminformation> is a reference-to-hash, giving information about the
returned item from the issues table.

C<$borrower> is a reference-to-hash, giving information about the
patron who last borrowed the book.

=cut

sub AddReturn {
    ## dropbox is for backwards compatibility: use returndate instead
    my ($barcode, $branch, $exemptfine, $dropbox, $returndate, $tolost) = @_;
    my $today         = C4::Dates->new();
    $returndate     ||= $today->output('iso');
    my $returndateObj = C4::Dates->new($returndate,'iso');

    if ($branch and not GetBranchDetail($branch)) {
        warn "AddReturn error: branch '$branch' not found.  Reverting to " . C4::Context->userenv->{'branch'};
        undef $branch;
    }
    $branch = C4::Context->userenv->{'branch'} unless $branch;  # we trust userenv to be a safe fallback/default
    my $messages;
    my $borrower;
    my $doreturn       = 1;
    my $validTransfert = 0;
    
    # get information on item
    my $itemnumber  = C4::Items::GetItemnumberFromBarcode( $barcode );
    unless ($itemnumber) {
        return (0, { BadBarcode => $barcode }); # no barcode means no item or borrower.  bail out.
    }

    ## fix possibly erroneous overdue flag from GetItemIssue()
    ## happens when checkin is backdated
    my $datedue;
    my $issue = GetItemIssue($itemnumber);
    my $biblio;
    my $resetNotdue = 0;
    if ($issue) {
        $$issue{returndate} = $returndate;
        $datedue = C4::Dates->new($$issue{date_due},'iso');
        my $rd   = $returndate; $rd =~ s/\D//g;
        my $dd   = $$issue{date_due}; $dd =~ s/\D//g;
        if ($$issue{overdue} && ($rd <= $dd)) {
            $$issue{overdue} = 0;
            $dropbox = 1;
            $resetNotdue = 1;
        }
        if ($returndate lt $$issue{issuedate}) {
            $$messages{ReturndateLtIssuedate} = $returndate;
            return (0,$messages,$issue,undef);
        }
        $biblio = GetBiblioItemData($issue->{'biblioitemnumber'});
    }
    if ($issue and $issue->{borrowernumber}) {
        $borrower = C4::Members::GetMemberDetails($issue->{borrowernumber})
            or die "Data inconsistency: barcode $barcode (itemnumber:$itemnumber) claims to be issued to non-existant borrowernumber '$issue->{borrowernumber}'\n"
                . Dumper($issue) . "\n";
    } else {
        # find the borrower
        if ( ( not $issue->{borrowernumber} ) && $doreturn ) {
            $messages->{'NotIssued'} = $barcode;
            # even though item is not on loan, it may still
            # be transferred; therefore, get current branch information
            my $curr_iteminfo = GetItem($itemnumber);
            $issue->{'homebranch'} = $curr_iteminfo->{'homebranch'};
            $issue->{'holdingbranch'} = $curr_iteminfo->{'holdingbranch'};
            $issue->{'itemlost'} = $curr_iteminfo->{'itemlost'};
            $doreturn = 0;
        }
    }
    my $item = C4::Items::GetItem($itemnumber) or die "GetItem($itemnumber) failed";
        # full item data, but no borrowernumber or checkout info (no issue)
        # we know GetItem should work because GetItemnumberFromBarcode worked
    my $hbr = $item->{C4::Context->preference("HomeOrHoldingBranch")} || '';
        # item must be from items table -- issues table has branchcode and issuingbranch, 
        # not homebranch nor holdingbranch
    my $borrowernumber = $borrower->{'borrowernumber'} || undef;    # we don't know if we had a borrower or not

    # check if the book is in a permanent collection....
    # FIXME -- This 'PE' attribute is largely undocumented.  afaict, there's no user interface that reflects this functionality.
    if ( $hbr ) {
    	  my $branches = GetBranches();    # a potentially expensive call for a non-feature.
        $branches->{$hbr}->{PE} and $messages->{'IsPermanent'} = $hbr;
    }

    # if indy branches and returning to different branch, refuse the return
    ## FIXME - even in an indy branches situation, there should
    ## still be an option for the library to accept the item
    ## and transfer it to its owning library.
	 ## Fixed and deprecated in circ/returns.pl -hQ
    #if (($hbr ne $branch) && C4::Context->preference("IndependantBranches")){
    #    $messages->{'Wrongbranch'} = {
    #        Wrongbranch => $branch,
    #        Rightbranch => $hbr,
    #    };
    #    $doreturn = 0 unless $$item{itemlost};
    # 	bailing out here - in this case, current desired behavior
    # 	is to act as if no return ever happened at all.
    # 	return ( $doreturn, $messages, $issue, $borrower ) unless $$item{itemlost};
    #}

    if ( $item->{'wthdrawn'} ) { # book has been cancelled
        $messages->{'wthdrawn'} = 1;
        $doreturn = 0;
    }

    # Set items.otherstatus back to NULL on check in regardless of whether the
    # item was actually checked out.
    C4::Items::ModItem({ otherstatus => undef }, $item->{'biblionumber'}, $item->{'itemnumber'});
    C4::Items::ModItem({ onloan      => undef }, $item->{'biblionumber'}, $item->{'itemnumber'});

    # Clear the notforloan status if syspref is turned ON and value is negative
    C4::Items::ModItem({ notforloan => 0 }, $item->{'biblionumber'}, $item->{'itemnumber'}) if (C4::Context->preference('ClearNotForLoan') && ($item->{'notforloan'} < 0));

    # case of a return of document (deal with issues and holdingbranch)
    if ($doreturn) {
        # $borrower or warn "AddReturn without current borrower";
        my $circControlBranch;
        if ($dropbox) {
            # define circControlBranch only if dropbox mode is set
            # don't allow dropbox mode to create an invalid entry in issues (issuedate > today)
            # FIXME: check issuedate > returndate, factoring in holidays
            $circControlBranch = GetCircControlBranch(
               pickup_branch      => $issue->{issuingbranch} // $issue->{branchcode},
               item_homebranch    => $item->{homebranch},
               item_holdingbranch => $item->{holdingbranch},
               borrower_branch    => $borrower->{branchcode},
            ) unless ($issue->{'issuedate'} eq C4::Dates->today('iso'));
        }

        if ($borrowernumber) {
            # over ride in effect if $returndate
                _MarkIssueReturned(
                    $borrower->{'borrowernumber'},
                    $issue->{'itemnumber'},
                    $circControlBranch,
                    $returndate);
            $messages->{'WasReturned'} = $borrower || 1;        
         }
    }

    # Needed to move this down below _MarkIssueReturned since most recent
    # return was still in the issues and not the old_issues table.
    if (   C4::Context->preference('AllowReadingHistoryAnonymizing')
        && !C4::Context->preference('KeepPreviousBorrower')
        && $borrower->{'disable_reading_history'} )
    {
        AnonymiseIssueHistory( '', $borrower->{'borrowernumber'} );
    }

    # the holdingbranch is updated if the document is returned to another location.
    # this is always done regardless of whether the item was on loan or not
    if ($item->{'holdingbranch'} ne $branch) {
        UpdateHoldingbranch($branch, $item->{'itemnumber'});
        $item->{'holdingbranch'} = $branch; # update item data holdingbranch too
    }
    C4::Items::ModDateLastSeen( $item->{'itemnumber'} );

    # check if we have a transfer for this document
    my ($datesent,$frombranch,$tobranch) = GetTransfers( $item->{'itemnumber'} );

    # if we have a transfer to do, we update the line of transfers with the datearrived
    if ($datesent) {
        if ( $tobranch eq $branch ) {
            my $sth = C4::Context->dbh->prepare(
                "UPDATE branchtransfers SET datearrived = now() WHERE itemnumber= ? AND datearrived IS NULL"
            );
            $sth->execute( $item->{'itemnumber'} );
            # if we have a reservation with valid transfer, we can set it's status to 'W'
            ## UPDATE: hold is trapped outside of and after AddReturn()... 
            ## transfer does not have to for hold but for other reasons -hQ
            #my ($resfound,$resrec) = C4::Reserves::CheckReserves($item->{'itemnumber'});
            #C4::Reserves::ModReserveStatus($item->{'itemnumber'}, 'W', $resrec) if ($resfound); # This function is also now deprecated, so don't uncomment this.
        } else {
            $messages->{'WrongTransfer'}     = $tobranch;
            $messages->{'WrongTransferItem'} = $item->{'itemnumber'};
        }
        $validTransfert = 1;
    }
    
    ## Treat row in lostitems separate from items.itemlost.
    ## This is because librarian can choose not to unlink lost item from 
    ## patron's account, so we have items.itemlost now 0 but lost_items defined.
    my $lostitem = GetLostItem($$item{itemnumber}) // {};

    if ($item->{'itemlost'} || $$lostitem{id}) {
        ## requires confirmation from WasLost; also messes up $tolost
        #DeleteLostItem($lost_item->{id});
        $messages->{'WasLost'} = {
            itemnumber          => $$item{itemnumber},
            lostborrowernumber  => $$lostitem{borrowernumber},
            issueborrowernumber => $$issue{borrowernumber},
            biblionumber        => $$lostitem{biblionumber},
            barcode             => $barcode,
            lost_item_id        => $$lostitem{id},
        };
        _FixAccountNowFound($$issue{borrowernumber},$lostitem,$returndateObj,$tolost);
    }

    # fix up the overdues in accounts...
    ## also does exemptfine but not claims returned
    if ($borrowernumber) {
       my $acctBranch = GetCircControlBranch(
            pickup_branch      => $issue->{issuingbranch} // $issue->{branchcode},
            item_homebranch    => $item->{homebranch},
            item_holdingbranch => $item->{holdingbranch},
            borrower_branch    => $borrower->{branchcode},
       ); 
        _FixAccountOverdues(
            $issue, {
                exemptfine    => $exemptfine, 
                returndate    => $returndate,
                branch        => $acctBranch,
                today         => $today,
                returndateObj => $returndateObj,
                borcatcode    => $$borrower{categorycode},
                datedueObj    => $datedue,
                atreturn      => 1,
                tolost        => $tolost,
            },
        );
    }

    # find reserves.....
    # if we don't have a reserve with the status W, we launch the Checkreserves routine
    my ($resfound, $resrec) = C4::Reserves::CheckReserves( $item->{'itemnumber'} );
    if ($resfound) {
        # For some reason, the itemnumber in $resrec was being returned as 
        # NULL.  Accidental change in the return workflow? At any rate, 
        # forcing itemnumber into $resrec.
        # FIXME: umm... this might be a bib-level hold, so there wouldn't be an 
        # itemnumber in the reserve record. -hQ
        $resrec->{'itemnumber'} = $item->{'itemnumber'};
          $resrec->{'ResFound'} = $resfound;
        $messages->{'ResFound'} = $resrec;
    }

    # update stats?
    # Record the fact that this book was returned.
    UpdateStats(
        $branch, 'return', '0', '',
        $item->{'itemnumber'},
        $biblio->{'itemtype'},
        $borrowernumber
    );

    # Send a check-in slip. # NOTE: borrower may be undef.  probably shouldn't try to send messages then.
    my $circulation_alert = 'C4::ItemCirculationAlertPreference';
    my %conditions = (
        branchcode   => $branch,
        categorycode => $borrower->{categorycode},
        item_type    => $item->{itype},
        notification => 'CHECKIN',
    );
    if ($doreturn && $circulation_alert->is_enabled_for(\%conditions)) {
        SendCirculationAlert({
            type     => 'CHECKIN',
            item     => $item,
            borrower => $borrower,
            branch   => $branch,
        });
    }
    
    logaction("CIRCULATION", "RETURN", $borrowernumber, $item->{'biblionumber'})
        if C4::Context->preference("ReturnLog");

    # FIXME: make this comment intelligible.
    #adding message if holdingbranch is non equal a userenv branch to return the document to homebranch
    #we check, if we don't have reserv or transfert for this document, if not, return it to homebranch .

    if (!$tolost && ($branch ne $item->{'homebranch'}) and not $messages->{'WrongTransfer'} and ($validTransfert ne 1) and not $resfound ){
        if ( C4::Context->preference("AutomaticItemReturn"    ) or
            (C4::Context->preference("UseBranchTransferLimits") and
             ! IsBranchTransferAllowed($branch, $hbr, $item->{C4::Context->preference("BranchTransferLimitsType")} )
           )) {
            ModItemTransfer($item->{'itemnumber'}, $branch, $item->{'homebranch'});
            $messages->{'WasTransfered'} = 1;
        } else {
            $messages->{'NeedsTransfer'} = 1;   # TODO: instead of 1, specify branchcode that the transfer SHOULD go to, $item->{homebranch}
        }
    }
    return ( $doreturn, $messages, $issue, $borrower );
}

=head2 _MarkIssueReturned

=over 4

_MarkIssueReturned($borrowernumber, $itemnumber, $dropbox_branch, $returndate);

=back

Unconditionally marks an issue as being returned by
moving the C<issues> row to C<old_issues> and
setting C<returndate> to the current date, or
the last non-holiday date of the branccode specified in
C<dropbox_branch> .  Assumes you've already checked that 
it's safe to do this, i.e. last non-holiday > issuedate.

if C<$returndate> is specified (in iso format), it is used as the date
of the return. It is ignored when a dropbox_branch is passed in.

Ideally, this function would be internal to C<C4::Circulation>,
not exported, but it is currently needed by one 
routine in C<C4::Accounts>.

=cut

sub _MarkIssueReturned {
    my ( $borrowernumber, $itemnumber, $dropbox_branch, $returndate ) = @_;
    my $dbh   = C4::Context->dbh;
    my $query = "UPDATE issues SET returndate=";
    my @bind;
    if ($dropbox_branch) {
        my $calendar = C4::Calendar->new( branchcode => $dropbox_branch );
        my $dropboxdate = $calendar->addDate( C4::Dates->new(), -1 );
        $query .= " ? ";
        push @bind, $dropboxdate->output('iso');
    } elsif ($returndate) {
        $query .= " ? ";
        push @bind, $returndate;
    } else {
        $query .= " now() ";
    }
    $query .= " WHERE  borrowernumber = ?  AND itemnumber = ?";
    push @bind, $borrowernumber, $itemnumber;
    # FIXME transaction
    my $sth_upd  = $dbh->prepare($query);
    $sth_upd->execute(@bind);
    my $sth_copy = $dbh->prepare("INSERT INTO old_issues SELECT * FROM issues 
                                  WHERE borrowernumber = ?
                                  AND itemnumber = ?");
    $sth_copy->execute($borrowernumber, $itemnumber);
    my $sth_del  = $dbh->prepare("DELETE FROM issues
                                  WHERE borrowernumber = ?
                                  AND itemnumber = ?");
    $sth_del->execute($borrowernumber, $itemnumber);
}

=head2 _FixAccountOverdues

    _FixAccountOverdues($issue, $flags)

C<$issue> : hashref of the pertinent row from the issues table

C<$flags> : hashref containing flags indicating checkin options. Can be one of:

    exemptfine: BOOL -- remove overdue charge associated with this issue. 
    dropbox: BOOL -- remove one business day from overdue charge associated with this issue.
    returndate: ISO date -- recalculate fine based on the item being returned on this date
    returndateObj: C4::Dates object of returndate
    overdue: BOOL

Returns nothing.

=cut

sub _chargeToAccount
{                                 # iso
   my($itemnumber,$borrowernumber,$issuedate,$isrenewal) = @_;
   return unless ($itemnumber && $borrowernumber && $issuedate);
   my($charge,$itemtype ) = GetIssuingCharges($itemnumber,$borrowernumber);
   $charge ||= 0;
   return ($charge,$itemtype) unless $charge > 0;
   my $text         = $isrenewal? 'renewed' : 'issued';
   my $issuedate_local = C4::Dates->new($issuedate,'iso')->output;
   my $dbh = C4::Context->dbh;
   my $sth = $dbh->prepare("SELECT 1 FROM accountlines
      WHERE accounttype    = 'Rent'
        AND itemnumber     = ?
        AND borrowernumber = ?
        AND description LIKE 'Rental fee, % $issuedate_local%'");
   $sth->execute($itemnumber,$borrowernumber);
   return ($charge, $itemtype) if $sth->fetchrow_array;
   $dbh->do("INSERT INTO accountlines (
         borrowernumber,
         accountno,
         itemnumber,
         description,
         `date`,
         amount,
         amountoutstanding,
         accounttype) VALUES (?,?,?,?,NOW(),?,?,'Rent')",undef,
      $borrowernumber,_getnextaccountno($borrowernumber),$itemnumber,
      "Rental fee, $text $issuedate_local",$charge,$charge);
   return $charge,$itemtype;
}

sub _FixAccountOverdues {
    my ($issue, $flags) = @_;
    return unless $issue;
    my $verbiage = $$flags{atreturn}? 'returned' : 'renewed';

    $$flags{datedueObj} //= C4::Dates->new($$issue{date_due},'iso');
    if (ref($$flags{returndateObj}) =~ /C4\:\:Dates/) {
        if (@{$$flags{returndateObj}{dmy_arrayref}}<=1) {
            $$flags{returndateObj} = C4::Dates->new();
        }
    }
    if (!$$flags{returndate} || !$$flags{returndateObj}) {
        if ($$flags{returndateObj}) { $$flags{returndate}    = $$flags{returndateObj}->output('iso')     }
        elsif ($$flags{returndate}) { $$flags{returndateOjb} = C4::Dates->new($$flags{returndate},'iso') }
        else {
            $$flags{returndateObj} = C4::Dates->new();
            $$flags{returndate}    = $$flags{returndateObj}->output('iso');
        }
    }

    my $dbh = C4::Context->dbh;
    my $sth;
    if (!$$issue{title}) {
        unless ($$issue{biblionumber}) { 
            my $item = GetItem($$issue{itemnumber});
            $$issue{biblionumber} = $$item{biblionumber};
        }
        $sth = $dbh->prepare('SELECT title FROM biblio WHERE biblionumber=?');
        $sth->execute($$issue{biblionumber});
        ($$issue{title}) = $sth->fetchrow_array() // '';
    }
    my $checkindate = $$flags{returndateObj}->output; # us
    my $duedate_local  = $$flags{datedueObj}->output;
    my $row = $dbh->selectrow_hashref(qq|
        SELECT *
         FROM accountlines
        WHERE borrowernumber = ?
          AND itemnumber     = ?
          AND description LIKE '%due on $duedate_local%'
          AND accounttype IN ('FU','F','O')
     ORDER BY accountno DESC
    |, undef, $$issue{borrowernumber}, $$issue{itemnumber});
    return if !$row && !$$issue{overdue}; ## not overdue, never charged

    my $start_date = C4::Dates->new($issue->{date_due}, 'iso');    
    ## fines.pl cron isn't running?
    if(!$row && $$issue{overdue}) { ## is overdue, not yet charged
        my($amount,$type,$daycounttotal,$daycount,$ismax) = C4::Overdues::CalcFine(
            C4::Items::GetItem($$issue{itemnumber}),
            $$flags{borcatcode},
            $$flags{branch},
            undef,undef,
            $$flags{datedueObj},
            $$flags{returndateObj},
        );
        if ($amount) { ## first, charge ...
            my $accountno = C4::Overdues::UpdateFine(
                $$issue{itemnumber}, 
                $$issue{borrowernumber}, 
                $amount, 
                'F', 
                $start_date->output,
                $ismax
            );
            ##.. then exempt fine
            _checkinDescFine($$issue{borrowernumber},$accountno,$checkindate,$$flags{tolost},$verbiage);
            _exemptFine($$issue{borrowernumber},$accountno) if ($$flags{exemptfine});
            _logFine($$issue{borrowernumber},"$verbiage item $$issue{itemnumber} $checkindate, $amount due",0) 
            if $$flags{atreturn};
        }
        return;
    }

    ## hereafter, we have accountline
    if ($$flags{exemptfine}) {
        _checkinDescFine($$issue{borrowernumber},$$row{accountno},$checkindate,$$flags{tolost},$verbiage);
        _exemptFine($$issue{borrowernumber},$$row{accountno});
        _rcrFine($issue,$row,0);
        _logFine($$issue{borrowernumber},"exempt fee item $$issue{itemnumber}",1);
        return;
    }
    elsif (!$$issue{overdue}) { # wow: backdate checkin where it's no longer overdue
        my $msg = 'adjusted to no longer overdue';
        $msg .= ", $verbiage $checkindate" if !$$flags{tolost};
        $dbh->do("UPDATE accountlines
            SET description = CONCAT(description, ', $msg'),
                amountoutstanding = 0,
                accounttype       = 'F'
          WHERE borrowernumber    = $$issue{borrowernumber}
            AND accountno         = $$row{accountno}
        ");
        _rcrFine($issue,$row,0);
        _logFine($$issue{borrowernumber},$msg,1);
        return;
    }

    ## else... still overdue
    my $item     = C4::Items::GetItem($$issue{itemnumber});
    my $borrower = C4::Members::GetMember($$issue{borrowernumber});
    my ($accounttype, $amount, $msg, $ismax) = ('F', $$row{amount}, undef, 0);
    if ($flags->{returndate}) {
        my $cal        = C4::Calendar->new(branchcode => $$flags{branch});
        my $enddateObj = $$flags{returndateObj};
        ($amount, undef, undef, undef, $ismax)
            = C4::Overdues::CalcFine($item, $borrower->{categorycode}, $$flags{branch},
                                     undef, undef, $start_date, $enddateObj);
        $msg = "adjusted backdate $verbiage item $$issue{itemnumber} $checkindate";
    }

    if ($amount && ($amount != $$row{amount})) {
        if ($amount < $$row{amount}) {
            ## lower both the amount and the amountoutstanding by diff cmp to new amount
            my $diff = $$row{amount} - $amount;
            my $newout = $$row{amountoutstanding} - $diff;
            my $tryRCR = 0;
            my $amountoutstanding = $newout;
            if ($amountoutstanding <0) {
               $tryRCR = 1;
               $amountoutstanding = 0;
            }
            if ($$row{description} =~ /max overdue/i) {
                $$row{description} =~ s/\, max overdue//i;
            }
            my $desc = $$flags{atreturn}? sprintf("$$row{description}, %s $checkindate", $$flags{tolost}? 'checkin as lost' : 'returned')
                                        : $$row{description};
            $dbh->do("UPDATE accountlines 
                SET accounttype       = 'F',
                    amount            = ?,
                    amountoutstanding = ?,
                    description       = ?
              WHERE borrowernumber    = ?
                AND accountno         = ?",undef,
                $amount,
                $amountoutstanding,
                $desc,
                $$issue{borrowernumber},
                $$row{accountno}
            );
            ##general case _rcrFine($issue,$row,$newout) doesn't apply
            RCR: {
               last RCR unless $tryRCR;
               my $paid = $$row{amount}-$$row{amountoutstanding};
               my $owed = -1*($paid-$amount) if ($paid > $amount);
               last RCR unless $owed;
               _rcrFine($issue,$row,$owed,1);
            }
        }
        else { # new amount is greater than previous
            C4::Overdues::UpdateFine(
                $issue->{itemnumber}, $issue->{borrowernumber}, $amount, 'F', $start_date->output,$ismax
            );
            _checkinDescFine($$issue{borrowernumber},$$row{accountno},$checkindate,$$flags{tolost},$verbiage);
        }
        _logFine($$issue{borrowernumber},$msg || "$verbiage item $$issue{itemnumber} $checkindate",1);
    }
    elsif ($$row{accountno} !~ /(returned|renewed) $checkindate/) {
        _checkinDescFine($$issue{borrowernumber},$$row{accountno},$checkindate,$$flags{tolost},$verbiage);
    }

    ## bogus
    #$dbh->do(q{
    #    UPDATE accountlines SET
    #      accounttype = ?,
    #      amountoutstanding = LEAST(amountoutstanding, amount)
    #    WHERE borrowernumber = ?
    #      AND itemnumber = ?
    #      AND accountno = ?
    #    }, undef,
    #    $accounttype, $issue->{borrowernumber}, $issue->{itemnumber}, $accountline->{accountno});
    #####

    return;
}

## don't call C4::Accounts, would be circular dependency
sub _FixAccountNowFound
{
    my($issuebor,$lostitem,$returndateObj,$tolost,$co) = @_;
    return unless (C4::Context->preference('RefundLostReturnedAmount') || C4::Context->preference('RefundReturnedLostItem'));
    return unless $lostitem;

    my $dbh = C4::Context->dbh;
    $returndateObj ||= C4::Dates->new();

    ## have they ever been charged for this lost item?
    my $sth = $dbh->prepare("SELECT * FROM accountlines
        WHERE accounttype    = 'L'
          AND itemnumber     = ?
          AND borrowernumber = ?
     ORDER BY accountno DESC");
    $sth->execute($$lostitem{itemnumber},$$lostitem{borrowernumber});
    my $lost = $sth->fetchrow_hashref() || return;

    ## update lost item accountline description
    ## tolost:   checkin as lost [date] by [librarian]                  ,tocredit=0
    ##   claimsreturned:                                                ,tocredit=1
    ## checkout: found at checkout [date] by [patron|other]             ,tocredit=1
    ## renewal:  found at renewal [date] by this patron                 ,tocredit=1
    ## default:  found and returned [date] by [patron|other|librarian]  ,tocredit=1
    my $desc = '';
    my $by   = 'by ';
    my $tocredit = 0;
    if ($tolost) { 
        $desc = 'checkin as lost';
    }
    elsif ($co ~~ 'renewal') {
        $desc = 'found at renewal';
        $tocredit = 1;
    }
    elsif ($co) { 
        $desc = 'found at checkout';
        $tocredit = 1;
    }
    else { 
        $desc = 'found and returned';    
        $tocredit = 1;
    }
    if ($issuebor && ($issuebor != $$lost{borrowernumber})) {
### for patron privacy, this feature is removed.  however, it is useful for circulation detective work
### even when patron circ history is anonymised
#        my $bor = C4::Members::GetMember($issuebor);
#        $by .= sprintf("a different patron (%s %s %s)",
#            $$bor{firstname},$$bor{surname},$$bor{cardnumber}
         $by .= 'a different patron';
#        );
    }
    elsif ($tolost) {
        my $userid = 'cron';
        if (my $userenv = C4::Context->userenv) { $userid = $userenv->{id} }
        $by .= sprintf('staff (-%s)',$userid);
    }
    elsif ( ($co ~~ 'renewal') || 
            ($issuebor && ($issuebor == $$lost{borrowernumber}))
          ) {
        $by .= 'this patron';
    }
    else {
        $by .= sprintf('staff (-%s)',C4::Context->userenv->{id});
    }
    $desc = sprintf("$$lost{description}, $desc %s $by", $returndateObj->output);
    $dbh->do(sprintf("UPDATE accountlines
        SET description    = ? %s
      WHERE borrowernumber = ?
        AND accountno      = ?", $tocredit? ", amountoutstanding=0, accounttype='CR'" : ''),undef,
        $desc,$$lost{borrowernumber},$$lost{accountno}
    );

    ## find previous claims returned
    $sth = $dbh->prepare("SELECT * FROM accountlines
        WHERE accounttype    = 'FOR'
          AND itemnumber     = ?
          AND borrowernumber = ?
          AND accountno      > ?
          AND description LIKE '%claims returned%'
          AND description NOT LIKE '%returned by%'
     ORDER BY accountno DESC");
    $sth->execute($$lostitem{itemnumber},$$lostitem{borrowernumber},$$lost{accountno});
    if (my $cr = $sth->fetchrow_hashref()) {
        my $desc = sprintf("$$cr{description}, returned %s by ",$returndateObj->output);
        if ($issuebor ~~ $$lostitem{borrowernumber}) {
            $desc .= 'this patron';
        }
        elsif ($issuebor) {
### for patron privacy, this feature is removed.  however, it is useful for circulation detective work
### even when patron circ history is anonymised
#            my $bor = C4::Members::GetMember($issuebor);
#            $desc .= "a different patron ($$bor{firstname} $$bor{surname}, $$bor{cardnumber})";
             $desc .= 'a different patron';
        }
        else {
            $desc .= sprintf("staff (-%s)",C4::Context->userenv->{id});
        }
        $dbh->do("UPDATE accountlines
            SET description    = ?
          WHERE itemnumber     = ?
            AND borrowernumber = ?
            AND accountno      = ?",undef,
            $desc,
            $$lostitem{itemnumber},
            $$lostitem{borrowernumber},
            $$cr{accountno},  
        );        
    }

    ## payment on lost item, with or without claims returned, needs RCR refund owed
    return unless $$lost{description} =~ /paid at no\.(\d+)/i;
    my $paid = $$lost{amount} - $$lost{amountoutstanding};
    return unless $paid;
    
    ## already RCR?
    $sth = $dbh->prepare("SELECT * FROM accountlines
        WHERE itemnumber     = ?
          AND borrowernumber = ?
          AND accounttype    = 'RCR'
          AND accountno      > ?
          AND description LIKE '%lost item%'
     ORDER BY accountno DESC");
    $sth->execute($$lostitem{itemnumber},$$lostitem{borrowernumber},$$lost{accountno});
    my $rcr = $sth->fetchrow_hashref();
    return if $rcr;
    
    my($nextno) = _getnextaccountno($$lostitem{borrowernumber});
    my $rcramount = -1 *($paid);
    $dbh->do("INSERT INTO accountlines (
            borrowernumber,
            accountno,
            itemnumber,
            date,
            amount,
            description,
            accounttype,
            amountoutstanding) 
        VALUES (?,?,?,NOW(),?,?,'RCR',?)",undef,
        $$lostitem{borrowernumber},
        $nextno,
        $$lostitem{itemnumber},
        $rcramount,
        "Refund owed at no.$$lost{accountno} for payment on lost item returned",
        $rcramount
    );                        
    return;  
}

sub _getnextaccountno
{
   my $borrowernumber = shift;
   my $sth = C4::Context->dbh->prepare('SELECT MAX(accountno)+1 FROM accountlines
        WHERE borrowernumber = ?
          AND borrowernumber IS NOT NULL');
   $sth->execute($borrowernumber);
   my($accountno) = $sth->fetchrow_array() || 1;
   return $accountno;
}

# RCR refund owed (not yet issued) for prior payment on overdue charges
sub _rcrFine
{
    my($iss,$acc,$newoutstanding,$amountIsOwed) = @_;
    return if $$acc{description} !~ /paid at no\.\d+/;

    ## the paid amount is amount-amountoutstanding
    ## the amount of refund owed is paid-newamountoutstanding, eg
    ##  originally due     $5.00    $7.00
    ##  paid               $1.00    $5.00
    ##  amountoutstanding  $4.00    $2.00
    ##  new overdue        $3.50    $4.00
    ##  refund owed        $0       $1.00   if paid>newamountoutstanding
    my $paid = my $owed = 0;
    if (!$amountIsOwed) {
       $paid = $$acc{amount} - $$acc{amountoutstanding};
       $owed = -1*($paid - $newoutstanding);
       return unless ($paid > $newoutstanding);
    }

    my $dbh = C4::Context->dbh;
    ## already have an RCR accountline
    ## theoretically, we would never fudge this line...
    my $sth = $dbh->prepare("SELECT accountno FROM accountlines
            WHERE accounttype    = 'RCR'
              AND borrowernumber = ?
              AND itemnumber     = ?
              AND description LIKE '%for payment on overdue%'
         ORDER BY accountno DESC");
    $sth->execute($$iss{borrowernumber},$$iss{itemnumber});
    if (my $dat = $sth->fetchrow_hashref()) {
        ##... doing this would never happen, since you can't checkin
        ## item twice for same due date
        my $setamount = 0;
        if ($amountIsOwed) {
            $setamount = $$dat{amount}+$newoutstanding;
        }
        elsif ($$dat{amount} != $owed) {
            $setamount = $$dat{amount}+$owed;
        }
        if ($setamount) {            
            $dbh->do("UPDATE accountlines
               SET amount         = ?, amountoutstanding = ?
             WHERE accountno      = ?
               AND borrowernumber = ?",undef,
            $setamount,$setamount,$$dat{accountno},$$iss{borrowernumber});
        } # else the refund amount is unchanged
        return;
    }
    
    ## else typical case: insert new RCR for refund owed
    ## avoid circular dependency by doing this here instead of in Accounts.pm
    my($nextnum)  = _getnextaccountno($$iss{borrowernumber});
    my $setamount = $amountIsOwed? $newoutstanding : $owed;
    $dbh->do("INSERT INTO accountlines (
            date,
            accountno,
            accounttype,
            borrowernumber,
            itemnumber,
            description,
            amount,
            amountoutstanding
        ) VALUES ( NOW(),?,'RCR',?,?,?,?,? )",undef,
        $nextnum,
        $$iss{borrowernumber},
        $$iss{itemnumber},
        "Refund owed at no.$$acc{accountno} for payment on overdue charges",
        $setamount,
        $setamount
    );
    return;
}

sub _checkinDescFine
{
    my $desc = $_[3]? 'checkin as lost' : $_[4];
    return C4::Context->dbh->do("UPDATE accountlines
        SET description    = CONCAT(description, ', $desc $_[2]')
      WHERE borrowernumber = ?
        AND accountno      = ?",undef,$_[0],$_[1]
    );
}

sub _logFine
{
    return unless C4::Context->preference('FinesLog');
    my($borrowernumber,$msg,$mod) = @_;
    return unless ($borrowernumber && $msg);
    logaction('FINES',$mod? 'MODIFY':undef,$borrowernumber,$msg);
    return;
}

sub _exemptFine
{
    my($bornum,$acctno) = @_;
    die "no borrowernumber: $!" unless $bornum;
    die "no accountno: $!"      unless $acctno;
    C4::Context->dbh->do("UPDATE accountlines
                SET description       = CONCAT(description,', Overdue forgiven'),
                    amountoutstanding = 0,
                    accounttype       = 'FFOR'
                WHERE borrowernumber  = $bornum
                  AND accountno       = $acctno
    ");
    return;
}

=head2 FixAccountForLostAndReturned

    &FixAccountForLostAndReturned($itemnumber, [$borrowernumber, $barcode]);

Calculates the charge for a book lost and returned.

FIXME: This function reflects how inscrutable fines logic is.  Fix both.
FIXME: Give a positive return value on success.  It might be the $borrowernumber who received credit, or the amount forgiven.

=cut

## used when toggling item LOST status in catalogue/updateitem.pl
## do not use in AddReturn()
sub FixAccountForLostAndReturned {
    my($itemnumber,$issue,$lost_id) = @_;
    my $dbh = C4::Context->dbh;
    if ((ref($issue) ~~ 'HASH') && $$issue{borrowernumber}) { # handle currently checked out
        my $bor = C4::Members::GetMember($$issue{borrowernumber});
        my $acctBranch = GetCircControlBranch(
               pickup_branch      => $issue->{issuingbranch} // $issue->{branchcode},
               item_homebranch    => $issue->{homebranch},
               item_holdingbranch => $issue->{holdingbranch},
               borrower_branch    => $bor->{branchcode},
        );
        _FixAccountOverdues(
            $issue, {
                branch        => $acctBranch,
                borcatcode    => $$bor{categorycode},
                atreturn      => 0,
            },
        );
    }

   DeleteLostItem($lost_id) if C4::Context->preference('MarkLostItemsReturned');
   return unless C4::Context->preference('RefundReturnedLostItem');
   ## check for charge made for lost book
   my $sth = $dbh->prepare("
      SELECT * FROM accountlines 
       WHERE itemnumber = ? 
         AND accounttype IN ('L','Rep')
    ORDER BY accountno DESC");
   $sth->execute($itemnumber);
   my $data = $sth->fetchrow_hashref;
   return unless $data;
   return unless $$data{amount};
   
   ## Update lost item accountype so we don't go through this again
   ## Yes, we might be fixing somebody else's account other than passed in $borrowernumber
   my $today = C4::Dates->new()->output;
   my $userenv = C4::Context->userenv;
   my $user = 'cron';
   if ($userenv) { $user = $userenv->{id} }
   $sth = $dbh->prepare(qq|
    /* this is like receiving a credit or writeoff */
      UPDATE accountlines
         SET accounttype       = 'LR',
             amountoutstanding = 0,
             description       = CONCAT(description,', NO LONGER LOST $today (-$user)')
       WHERE accountno         = ?
         AND borrowernumber    = ?
         AND itemnumber        = ?|);
   $sth->execute($$data{accountno},$$data{borrowernumber},$itemnumber);

   return if $$data{description} =~ /writeoff at no\.\d+/i;
   if ($$data{description} =~ /claims returned at no\.(\d+)/) {
      my $desc = sprintf(", NO LONGER LOST %s (-%s)",C4::Dates->new()->output(),$user);
      $dbh->do("UPDATE accountlines
         SET  description = CONCAT(description,?)
        WHERE description NOT RLIKE 'NO LONGER LOST'
          AND borrowernumber = ?
          AND accountno      = ?",undef,
         $desc,$$data{borrowernumber},$1);
   }
   if ($$data{description} =~ /paid at no\./) {
      ## see if we already receive a refund owed (RCR), eg from payment before Claims Returned
      $sth = $dbh->prepare("SELECT * FROM accountlines
        WHERE borrowernumber = ?
          AND itemnumber     = ?
          AND accounttype    = 'RCR'
          AND description RLIKE 'Refund owed at no.$$data{accountno}'
          AND accountno      > ?");
       $sth->execute($$data{borrowernumber},$itemnumber,$$data{accountno});
       return if $sth->fetchrow_hashref();
   }
   my $paid = $$data{amount} - $$data{amountoutstanding};
   return unless $paid;
   return unless $$data{description} =~ /paid at no\.\d+/i; # could be Claims Returned

   ## receive a refund on payment made
   ## syspref RefundLostReturnedAmount here would mess things up.  We simply do the lineitem
   ## accounting and let manual refund by librarian happen elsewhere.
   ## credit the amount of the lost item, RCR signifies a type of credit that can be refunded if
   ## a payment can be/was made on it.
   my $newno = _getnextaccountno($$data{borrowernumber});
   $sth = $dbh->prepare(q|
      INSERT INTO accountlines(
            accountno,
            borrowernumber,
            amount,
            amountoutstanding,
            description,
            itemnumber,
            accounttype,
            date)
      VALUES (?,?,?,?,?,?,?,NOW())|);
   $sth->execute($newno,$$data{borrowernumber},-1*$paid,-1*$paid,
   "Refund owed at no.$$data{accountno} for payment (in part or full) on lost item found",
   $itemnumber,'RCR');
   ## FIXME: this should be in the payment process, not here at the refund process
   ModItem({ paidfor => '' }, undef, $itemnumber);
   return 1;
}

=head2 GetCircControlBranch

   my $circ_control_branch = GetCircControlBranch(%args);

Args:

C<pickup_branch> : typically the logged in branch, or the issuing branch
C<borrower_branch> or C<borrower_branchcode>
C<item_homebranch> and/or C<item_holdingbranch>

Internal function : 

Return the library code to be used to determine which circulation
policy applies to a transaction.  Looks up the CircControl and
HomeOrHoldingBranch system preferences.

=cut

sub GetCircControlBranch {
   my %g = @_;
   $g{pickup_branch}   //= $g{pickup_branchcode} // $g{issuingbranch} // $g{issue_branch} // $g{issue_branchcode};
   $g{borrower_branch} //= $g{borrower_branchcode};
   die "pickup_branch required"   unless $g{pickup_branch};
   die "borrower_branch required" unless $g{borrower_branch};
   die "item_homebranch required" unless $g{item_homebranch};
   my $control       = C4::Context->preference('CircControl');
#   my $homeOrHolding = C4::Context->preference('HomeOrHoldingBranch') || 'homebranch';
   if    ($control eq 'PickupLibrary') { return $g{pickup_branch}   }
   elsif ($control eq 'PatronLibrary') { return $g{borrower_branch} }

#### actually, the syspref HomeOrHoldingBranch doesn't apply for circrules
#### otherwise, CircContorl=ItemHomeBranch would conflict with HomeOrHoldingBranch=holdingbranch
#   if ($homeOrHolding eq 'holdingbranch') {
#      die "item_holdingbranch required" unless $g{item_holdingbranch};
#   }
#   return $g{"item_$homeOrHolding"};
   return $g{"item_homebranch"};
}


=head2 GetItemIssue

$issue = &GetItemIssue($itemnumber);

Returns patron currently having a book, or undef if not checked out.

C<$itemnumber> is the itemnumber.

C<$issue> is a hashref of the row from the issues table.

=cut

sub GetItemIssue {
    my($itemnumber,$borrowernumber) = @_;
    return unless $itemnumber;
    my @vals = ($itemnumber);
    my $and = '';
    if ($borrowernumber) {
      $and = 'AND s.borrowernumber=?';
      push @vals, $borrowernumber;
    }
    
    my $sth = C4::Context->dbh->prepare("
      SELECT s.*,i.biblionumber,b.title,i.homebranch,i.holdingbranch,
             p.firstname,p.surname,p.cardnumber,p.categorycode
        FROM issues s, items i, biblio b, borrowers p
       WHERE s.itemnumber     = ? $and 
         AND s.itemnumber     = i.itemnumber
         AND i.biblionumber   = b.biblionumber
         AND p.borrowernumber = s.borrowernumber
    ");
    $sth->execute(@vals);
    my $data = $sth->fetchrow_hashref;
    return unless $data;
    $data->{'overdue'} = ($data->{'date_due'} lt C4::Dates->today('iso')) ? 1 : 0;
    return ($data);
}

=head2 GetOpenIssue

$issue = GetOpenIssue( $itemnumber );

Returns the row from the issues table if the item is currently issued, undef if the item is not currently issued

C<$itemnumber> is the item's itemnumber

Returns a hashref

=cut

sub GetOpenIssue {
  my ( $itemnumber ) = @_;

  my $dbh = C4::Context->dbh;  
  my $sth = $dbh->prepare( "SELECT * FROM issues WHERE itemnumber = ? AND returndate IS NULL" );
  $sth->execute( $itemnumber );
  my $issue = $sth->fetchrow_hashref();
  return $issue;
}

=head2 GetItemIssues

$issues = &GetItemIssues($itemnumber, $history);

Returns patrons that have issued a book

C<$itemnumber> is the itemnumber
C<$history> is false if you just want the current "issuer" (if any)
and true if you want issues history from old_issues also.

Returns reference to an array of hashes

=cut

sub GetOldIssue {
   my $itemnumber = shift;
   my $dbh = C4::Context->dbh;
   my $sth = $dbh->prepare('SELECT * FROM old_issues
      WHERE itemnumber = ?
      ORDER BY returndate DESC, timestamp DESC
      LIMIT 1');
   $sth->execute($itemnumber);
   return $sth->fetchrow_hashref();
}

sub GetItemIssues {
    my ( $itemnumber, $history ) = @_;
    
    my $today = C4::Dates->today('iso');  # get today date
    my $sql = "SELECT * FROM issues 
              JOIN borrowers USING (borrowernumber)
              JOIN items     USING (itemnumber)
              WHERE issues.itemnumber = ? ";
    if ($history) {
        $sql .= "UNION ALL
                 SELECT * FROM old_issues 
                 LEFT JOIN borrowers USING (borrowernumber)
                 JOIN items USING (itemnumber)
                 WHERE old_issues.itemnumber = ?
                 ORDER BY returndate DESC";
    }
    my $sth = C4::Context->dbh->prepare($sql);
    if ($history) {
        $sth->execute($itemnumber, $itemnumber);
    } else {
        $sth->execute($itemnumber);
    }
    my $results = $sth->fetchall_arrayref({});
    foreach (@$results) {
        $_->{'overdue'} = ($_->{'date_due'} lt $today) ? 1 : 0;
    }
    return $results;
}

=head2 GetBiblioIssues

$issues = GetBiblioIssues($biblionumber);

this function get all issues from a biblionumber.

Return:
C<$issues> is a reference to array which each value is ref-to-hash. This ref-to-hash containts all column from
tables issues and the firstname,surname & cardnumber from borrowers.

=cut

sub GetBiblioIssues {
    my $biblionumber = shift;
    return undef unless $biblionumber;
    my $dbh   = C4::Context->dbh;
    my $query = "
        SELECT issues.*,items.barcode,biblio.biblionumber,biblio.title, biblio.author,borrowers.cardnumber,borrowers.surname,borrowers.firstname
        FROM issues
            LEFT JOIN borrowers ON borrowers.borrowernumber = issues.borrowernumber
            LEFT JOIN items ON issues.itemnumber = items.itemnumber
            LEFT JOIN biblioitems ON items.itemnumber = biblioitems.biblioitemnumber
            LEFT JOIN biblio ON biblio.biblionumber = items.biblionumber
        WHERE biblio.biblionumber = ?
        UNION ALL
        SELECT old_issues.*,items.barcode,biblio.biblionumber,biblio.title, biblio.author,borrowers.cardnumber,borrowers.surname,borrowers.firstname
        FROM old_issues
            LEFT JOIN borrowers ON borrowers.borrowernumber = old_issues.borrowernumber
            LEFT JOIN items ON old_issues.itemnumber = items.itemnumber
            LEFT JOIN biblioitems ON items.itemnumber = biblioitems.biblioitemnumber
            LEFT JOIN biblio ON biblio.biblionumber = items.biblionumber
        WHERE biblio.biblionumber = ?
        ORDER BY timestamp
    ";
    my $sth = $dbh->prepare($query);
    $sth->execute($biblionumber, $biblionumber);

    my @issues;
    while ( my $data = $sth->fetchrow_hashref ) {
        push @issues, $data;
    }
    return \@issues;
}

=head2 GetUpcomingDueIssues

=over 4
 
my $upcoming_dues = GetUpcomingDueIssues( { days_in_advance => 4 } );

=back

=cut

sub GetUpcomingDueIssues {
    my $params = shift;

    $params->{'days_in_advance'} = 7 unless exists $params->{'days_in_advance'};

    my $statement = <<END_SQL;
SELECT issues.*, items.itype as itemtype, items.homebranch, TO_DAYS( date_due )-TO_DAYS( NOW() ) as days_until_due, items.barcode, items.holdingbranch
FROM issues 
LEFT JOIN items USING (itemnumber)
WHERE returndate is NULL
AND ( TO_DAYS( date_due )-TO_DAYS( NOW() ) ) BETWEEN 0 AND ?
END_SQL

    my @bind_parameters = ( $params->{'days_in_advance'} );
    return C4::Context->dbh->selectall_arrayref(
        $statement, {Slice=>{}}, @bind_parameters);
}

=head2 CanBookBeRenewed

($ok,$error) = &CanBookBeRenewed($borrowernumber, $itemnumber[, $override_limit]);

Find out whether a borrowed item may be renewed.

C<$dbh> is a DBI handle to the Koha database.

C<$borrowernumber> is the borrower number of the patron who currently
has the item on loan.

C<$itemnumber> is the number of the item to renew.

C<$override_limit>, if supplied with a true value, causes
the limit on the number of times that the loan can be renewed
(as controlled by the item type) to be ignored.

C<$CanBookBeRenewed> returns a true value iff the item may be renewed. The
item must currently be on loan to the specified borrower; renewals
must be allowed for the item's type; and the borrower must not have
already renewed the loan. $error will contain the reason the renewal can not proceed

=cut

sub CanBookBeRenewed {

    # check renewal status
    my ( $borrowernumber, $itemnumber, $override_limit ) = @_;
    my $dbh       = C4::Context->dbh;
    my $renews    = 1;
    my $renewokay = 0;
    my $error;

    # Look in the issues table for this item, lent to this borrower,
    # and not yet returned.

    # FIXME - I think this function could be redone to use only one SQL call.
    my $sth1 = $dbh->prepare(
        "SELECT * FROM issues
            WHERE borrowernumber = ?
            AND itemnumber = ?"
    );
    $sth1->execute( $borrowernumber, $itemnumber );
    if ( my $data1 = $sth1->fetchrow_hashref ) {

        # Found a matching item

        # See if this item may be renewed. This query is convoluted
        # because it's a bit messy: given the item number, we need to find
        # the biblioitem, which gives us the itemtype, which tells us
        # whether it may be renewed.
        my $query = "SELECT renewalsallowed FROM items ";
        $query .= (C4::Context->preference('item-level_itypes'))
                    ? "LEFT JOIN itemtypes ON items.itype = itemtypes.itemtype "
                    : "LEFT JOIN biblioitems on items.biblioitemnumber = biblioitems.biblioitemnumber
                       LEFT JOIN itemtypes ON biblioitems.itemtype = itemtypes.itemtype ";
        $query .= "WHERE items.itemnumber = ?";
        my $sth2 = $dbh->prepare($query);
        $sth2->execute($itemnumber);
        if ( my $data2 = $sth2->fetchrow_hashref ) {
            $renews = $data2->{'renewalsallowed'};
        }
        if ( ( ($renews // 0) > ($data1->{'renewals'} // 0) ) || $override_limit ) {
            $renewokay = 1;
        }
        else {
            $error="too_many";
        }
        $sth2->finish;
        my ( $resfound, $resrec ) = C4::Reserves::CheckReserves($itemnumber);
        if ($resfound) {
            $renewokay = 0;
            $error="on_reserve"
        }

    }
    $sth1->finish;
    return ($renewokay,$error);
}

=head2 AddRenewal

&AddRenewal(%args);

Renews a loan.

C<$borrowernumber> is the borrower number of the patron who currently
has the item.

C<$itemnumber> is the number of the item to renew.

C<$branch> is the library where the renewal took place (if any).
           The library that controls the circ policies for the renewal is retrieved from the issues record.

C<$datedue> can be a C4::Dates object used to set the due date.

C<$lastreneweddate> is an optional ISO-formatted date used to set issues.lastreneweddate.  If
this parameter is not supplied, lastreneweddate is set to the current date.

If C<$datedue> is the empty string, C<&AddRenewal> will calculate the due date automatically
from the book's item type.

=cut

sub AddRenewal {
   my %g = @_;
   my $issue           = $g{issue};
   my $itemnumber      = $g{itemnumber}      || $$issue{itemnumber}                     || return;
   my $item            = $g{item}            || GetItem($itemnumber)                    || return;
   my $biblio          = $g{biblio}          || GetBiblioFromItemNumber($itemnumber)    || return;
   my $lastreneweddate = $g{lastreneweddate} || C4::Dates->new()->output('iso');
   my $source          = $g{source}          || ''; #FIMXE: what is the default?
   my $borrowernumber  = $g{borrowernumber}  || $$issue{borrowernumber}                 || return;
   my $borrower        = $g{borrower}        || C4::Members::GetMember($borrowernumber) || return;
   my $datedue         = $g{datedueObj}      || $g{datedue} || '';
   my $issuedate       = $g{issuedate}       || C4::Dates->new()->output('iso');
   $issue            ||= GetItemIssue($itemnumber,$borrowernumber);
   $itemnumber       ||= $$issue{itemnumber};
   $borrowernumber   ||= $$issue{borrowernumber};
   my $lostitem        = $g{lostitem} || GetLostItem($itemnumber);
   if ($datedue && (ref($datedue) !~ /C4\:\:Dates/)) { # not an object
      $datedue = C4::Dates->new($datedue);
   }
   my $currBranch;
   if (C4::Context->userenv) { $currBranch = C4::Context->userenv->{branch} }
   else                      { $currBranch = $$issue{issuingbranch}         }
   my $branch = GetCircControlBranch(
      pickup_branch      => $issue->{issuingbranch} // $issue->{branchcode},
      item_homebranch    => $item->{homebranch},
      item_holdingbranch => $item->{holdingbranch},
      borrower_branch    => $borrower->{branchcode},
   );

    unless ($datedue && $datedue->output('iso')) {
        my $loanlength = GetLoanLength(
            $borrower->{'categorycode'},
             (C4::Context->preference('item-level_itypes')) ? $biblio->{'itype'} : $biblio->{'itemtype'} ,
            $branch
        );
        ## FIXME: why go through this trouble if datedue later uses today?
#        $datedue = (C4::Context->preference('RenewalPeriodBase') eq 'date_due') ?
#                                        C4::Dates->new($issue->{date_due}, 'iso') :
#                                        C4::Dates->new(); # FIXME: datedue=today?
        $datedue =  CalcDateDue(C4::Dates->new(),$loanlength,$branch,$borrower);
    }
    die "Invalid date passed to AddRenewal." if ($datedue && ! $datedue->output('iso'));
    my $today = C4::Dates->new->output('iso');
    if ($datedue->output('iso') lt $today) {
        warn <<EOF;
Date due can't be prior to today.
Setting date due = $today for borrower: $borrowernumber
item number: $itemnumber.
EOF
        $datedue = C4::Dates->new;
    }

    # Update the issues record to have the new due date, and a new count
    # of how many times it has been renewed.
    my $dbh = C4::Context->dbh;
    my $renews = ($issue->{'renewals'} // 0) + 1;
    my $sth = $dbh->prepare("UPDATE issues SET date_due = ?, renewals = ?, lastreneweddate = ?, branchcode=?
                            WHERE borrowernumber=? 
                            AND itemnumber=?"
    );
    $sth->execute( $datedue->output('iso'), 
      $renews, 
      $lastreneweddate,
      $currBranch,
      $borrowernumber, 
      $itemnumber 
   );
    $sth->finish;
    my %mod = ( 
       renewals => $renews,
       onloan   => $datedue->output('iso'),
       itemlost => 0,
    );
    my($charge) = _chargeToAccount($$item{itemnumber},$$borrower{borrowernumber},$issuedate,1);

    ModItem(\%mod, $biblio->{'biblionumber'}, $itemnumber);

    _FixAccountOverdues(
      $issue, {
         exemptfine    => $g{exemptfine},
         branch        => $branch,
         borcatcode    => $$borrower{categorycode},
         atreturn      => 0, # at renewal
         tolost        => 0, # no!
      },
    );

   _FixAccountNowFound($$borrower{borrowernumber},$lostitem,C4::Dates->new(),0,'renewal');
   C4::LostItems::DeleteLostItemByItemnumber($itemnumber);

   ## sanity checks: remove from transfers and holdsqueue
   C4::Reserves::RmFromHoldsQueue(itemnumber=>$itemnumber);
   DeleteTransfer($itemnumber);

   # Log the renewal
   UpdateStats( $branch, 'renew', $charge, $source, $itemnumber, $item->{itype}, $borrowernumber);
   return $datedue->output('iso');
}

sub GetRenewCount {
    # check renewal status
    my ($bornum,$itemno)=@_;
    my $dbh = C4::Context->dbh;
    my $renewcount = 0;
        my $renewsallowed = 0;
        my $renewsleft = 0;
    # Look in the issues table for this item, lent to this borrower,
    # and not yet returned.

    # FIXME - I think this function could be redone to use only one SQL call.
    my $sth = $dbh->prepare("select * from issues
                                where (borrowernumber = ?)
                                and (itemnumber = ?)");
    $sth->execute($bornum,$itemno);
    my $data = $sth->fetchrow_hashref;
    $renewcount = $data->{'renewals'} if $data->{'renewals'};
    $sth->finish;
    my $query = "SELECT renewalsallowed FROM items ";
    $query .= (C4::Context->preference('item-level_itypes'))
                ? "LEFT JOIN itemtypes ON items.itype = itemtypes.itemtype "
                : "LEFT JOIN biblioitems on items.biblioitemnumber = biblioitems.biblioitemnumber
                   LEFT JOIN itemtypes ON biblioitems.itemtype = itemtypes.itemtype ";
    $query .= "WHERE items.itemnumber = ?";
    my $sth2 = $dbh->prepare($query);
    $sth2->execute($itemno);
    my $data2 = $sth2->fetchrow_hashref();
    $renewsallowed = $data2->{'renewalsallowed'};
    $renewsleft = $renewsallowed - $renewcount;
    return ($renewcount,$renewsallowed,$renewsleft);
}

=head2 GetIssuingCharges

($charge, $item_type) = &GetIssuingCharges($itemnumber, $borrowernumber);

Calculate how much it would cost for a given patron to borrow a given
item, including any applicable discounts.

C<$itemnumber> is the item number of item the patron wishes to borrow.

C<$borrowernumber> is the patron's borrower number.

C<&GetIssuingCharges> returns two values: C<$charge> is the rental charge,
and C<$item_type> is the code for the item's item type (e.g., C<VID>
if it's a video).

=cut

sub GetIssuingCharges {

    # calculate charges due
    my ( $itemnumber, $borrowernumber ) = @_;
    my $charge = 0;
    my $dbh    = C4::Context->dbh;
    my $item_type;

    # Get the book's item type and rental charge (via its biblioitem).
    my $qcharge =     "SELECT itemtypes.itemtype,rentalcharge FROM items
            LEFT JOIN biblioitems ON biblioitems.biblioitemnumber = items.biblioitemnumber";
    $qcharge .= (C4::Context->preference('item-level_itypes'))
                ? " LEFT JOIN itemtypes ON items.itype = itemtypes.itemtype "
                : " LEFT JOIN itemtypes ON biblioitems.itemtype = itemtypes.itemtype ";
    
    $qcharge .=      "WHERE items.itemnumber =?";
   
    my $sth1 = $dbh->prepare($qcharge);
    $sth1->execute($itemnumber);
    if ( my $data1 = $sth1->fetchrow_hashref ) {
        $item_type = $data1->{'itemtype'};
        $charge    = $data1->{'rentalcharge'};
        my $q2 = "SELECT rentaldiscount FROM borrowers
            LEFT JOIN issuingrules ON borrowers.categorycode = issuingrules.categorycode
            WHERE borrowers.borrowernumber = ?
            AND issuingrules.itemtype = ?";
        my $sth2 = $dbh->prepare($q2);
        $sth2->execute( $borrowernumber, $item_type );
        if ( my $data2 = $sth2->fetchrow_hashref ) {
            my $discount = $data2->{rentaldiscount} // 0;
            $charge = ( $charge * ( 100 - $discount ) ) / 100;
        }
        $sth2->finish;
    }

    $sth1->finish;
    return ( $charge, $item_type );
}


=head2 GetTransfers

GetTransfers($itemnumber);

=cut

sub GetTransfers {
    my ($itemnumber) = @_;
    my $dbh = C4::Context->dbh;
    my $query = '
        SELECT datesent,
               frombranch,
               tobranch
        FROM branchtransfers
        WHERE itemnumber = ?
          AND datearrived IS NULL
        ';
    my $sth = $dbh->prepare($query);
    $sth->execute($itemnumber);
    my @row = $sth->fetchrow_array();
    $sth->finish;
    return @row;
}

=head2 GetTransfersFromTo

@results = GetTransfersFromTo($frombranch,$tobranch);

Returns the list of pending transfers between $from and $to branch

=cut

sub GetTransfersFromTo {
    my ( $frombranch, $tobranch ) = @_;
    return unless ( $frombranch && $tobranch );
    my $dbh   = C4::Context->dbh;
    my $query = "
        SELECT itemnumber,datesent,frombranch
        FROM   branchtransfers
        WHERE  frombranch=?
          AND  tobranch=?
          AND datearrived IS NULL
    ";
    my $sth = $dbh->prepare($query);
    $sth->execute( $frombranch, $tobranch );
    my @gettransfers;

    while ( my $data = $sth->fetchrow_hashref ) {
        push @gettransfers, $data;
    }
    $sth->finish;
    return (@gettransfers);
}

=head2 GetRenewalDetails

( $intranet_renewals, $opac_renewals ) = GetRenewalDetails( $itemnumber, $borrowernumber );

Returns the number of renewals through intranet and opac for the given itemnumber, limited by $renewals_limit

=cut

sub GetRenewalDetails {
    my ( $itemnumber, $borrowernumber ) = @_;
    my $dbh   = C4::Context->dbh;
    my $query = "SELECT other,count(*) as counter FROM statistics WHERE type = 'renew' AND borrowernumber = ? AND itemnumber= ? GROUP BY other";
    my $sth = $dbh->prepare($query);
    $sth->execute( $borrowernumber, $itemnumber );

    my $renewals_intranet = 0;
    my $renewals_opac = 0;

    while ( my $data = $sth->fetchrow_hashref ) {
      if ( $data->{other} && $data->{'other'} eq 'opac' ) {
    $renewals_opac+= $data->{'counter'};
      } else {
        $renewals_intranet+= $data->{'counter'};
      }
    }

    return ( $renewals_intranet, $renewals_opac );
}

=head2 DeleteTransfer

&DeleteTransfer($itemnumber);

=cut

sub DeleteTransfer {
    my $itemnumber = shift;
    return unless $itemnumber;
    C4::Context->dbh->do(
        "DELETE FROM branchtransfers
         WHERE itemnumber=? ",undef,$itemnumber
    );
}

=head2 AnonymiseIssueHistory

$rows = AnonymiseIssueHistory($borrowernumber,$date)

This function write NULL instead of C<$borrowernumber> given on input arg into the table issues.
if C<$borrowernumber> is not set, it will delete the issue history for all borrower older than C<$date>.

return the number of affected rows.

=cut

sub AnonymiseIssueHistory {
    my $date           = shift;
    my $borrowernumber = shift;
    my $itemnumber     = shift;
    
    return 0 unless ( $date || $borrowernumber ); ## For safety

    my @bind;
    my $query = q{
        UPDATE old_issues
        SET    borrowernumber = NULL
        WHERE  borrowernumber IS NOT NULL
    };
    if ($date) {
        $query .= ' AND returndate < ? ';
        push @bind, $date;
    }
    if ($borrowernumber) {
        $query .= ' AND borrowernumber = ? ';
        push @bind, $borrowernumber;
    }
    if ($itemnumber) {
        $query .= ' AND itemnumber = ? ';
        push @bind, $itemnumber;
    }

    return C4::Context->dbh->do($query, undef, @bind);
}

sub AnonymisePreviousBorrowers {
    my $interval = shift;

    return undef unless C4::Context->preference('AllowReadingHistoryAnonymizing');
    
    my $query = q{
        UPDATE borrowers b
          JOIN old_issues oi ON (b.borrowernumber = oi.borrowernumber)
        SET oi.borrowernumber = NULL
        WHERE b.disable_reading_history = 1
          AND returndate < NOW() - INTERVAL ? DAY
    };
    C4::Context->dbh->do($query, undef, $interval);
}

=head2 SendCirculationAlert

Send out a C<check-in> or C<checkout> alert using the messaging system.

B<Parameters>:

=over 4

=item type

Valid values for this parameter are: C<CHECKIN> and C<CHECKOUT>.

=item item

Hashref of information about the item being checked in or out.

=item borrower

Hashref of information about the borrower of the item.

=item branch

The branchcode from where the checkout or check-in took place.

=back

B<Example>:

    SendCirculationAlert({
        type     => 'CHECKOUT',
        item     => $item,
        borrower => $borrower,
        branch   => $branch,
    });

=cut

sub SendCirculationAlert {
    my ($opts) = @_;
    my ($type, $item, $borrower, $branch) =
        ($opts->{type}, $opts->{item}, $opts->{borrower}, $opts->{branch});
    my %message_name = (
        CHECKIN  => 'Item Check-in',
        CHECKOUT => 'Item Checkout',
    );
    my $borrower_preferences = C4::Members::Messaging::GetMessagingPreferences({
        borrowernumber => $borrower->{borrowernumber},
        message_name   => $message_name{$type},
    });
    my $letter = C4::Letters::getletter('circulation', $type);
    C4::Letters::parseletter($letter, 'biblio',      $item->{biblionumber});
    C4::Letters::parseletter($letter, 'biblioitems', $item->{biblionumber});
    C4::Letters::parseletter($letter, 'borrowers',   $borrower->{borrowernumber});
    C4::Letters::parseletter($letter, 'branches',    $branch);
    C4::Letters::parseletter($letter, 'items', $item->{itemnumber}, $type);
    my @transports = @{ $borrower_preferences->{transports} };
    # warn "no transports" unless @transports;
    for (@transports) {
        # warn "transport: $_";
        my $message = C4::Message->find_last_message($borrower, $type, $_);
        if (!$message) {
            #warn "create new message";
            C4::Message->enqueue($letter, $borrower, $_);
        } else {
            #warn "append to old message";
            $message->append($letter);
            $message->update;
        }
    }
    $letter;
}

=head2 updateWrongTransfer

$items = updateWrongTransfer($itemNumber,$borrowernumber,$waitingAtLibrary,$FromLibrary);

This function validate the line of brachtransfer but with the wrong destination (mistake from a librarian ...), and create a new line in branchtransfer from the actual library to the original library of reservation 

=cut

sub updateWrongTransfer {
    my ( $itemNumber,$waitingAtLibrary,$FromLibrary ) = @_;
    my $dbh = C4::Context->dbh; 
# first step validate the actual line of transfert .
    my $sth =
            $dbh->prepare(
            "update branchtransfers set datearrived = now(),tobranch=?,comments='wrongtransfer' where itemnumber= ? AND datearrived IS NULL"
            );
            $sth->execute($FromLibrary,$itemNumber);
            $sth->finish;

# second step create a new line of branchtransfer to the right location .
    ModItemTransfer($itemNumber, $FromLibrary, $waitingAtLibrary);

#third step changing holdingbranch of item
    UpdateHoldingbranch($FromLibrary,$itemNumber);
}

=head2 UpdateHoldingbranch

$items = UpdateHoldingbranch($branch,$itmenumber);
Simple methode for updating hodlingbranch in items BDD line

=cut

sub UpdateHoldingbranch {
    my ( $branch,$itemnumber ) = @_;
    ModItem({ holdingbranch => $branch }, undef, $itemnumber);
}

=head2 CalcDateDue

$newdatedue = CalcDateDue($startdate,$loanlength,$branchcode);
this function calculates the due date given the loan length ,
checking against the holidays calendar as per the 'useDaysMode' syspref.
C<$startdate>   = C4::Dates object representing start date of loan period (assumed to be today)
C<$branch>  = location whose calendar to use
C<$loanlength>  = loan length prior to adjustment
=cut

sub CalcDateDue { 
    my ($startdate,$loanlength,$branch,$borrower) = @_;
    my $datedue;

    if(C4::Context->preference('useDaysMode') eq 'Days') {  # ignoring calendar
        my $timedue = time + ($loanlength) * 86400;
    #FIXME - assumes now even though we take a startdate 
        my @datearr  = localtime($timedue);
        $datedue = C4::Dates->new( sprintf("%04d-%02d-%02d", 1900 + $datearr[5], $datearr[4] + 1, $datearr[3]), 'iso');
    } else {
        my $calendar = C4::Calendar->new(  branchcode => $branch );
        $datedue = $calendar->addDate($startdate, $loanlength);
    }

    # if ReturnBeforeExpiry ON the datedue can't be after borrower expirydate
    if ( C4::Context->preference('ReturnBeforeExpiry') && $datedue->output('iso') gt $borrower->{dateexpiry} ) {
        $datedue = C4::Dates->new( $borrower->{dateexpiry}, 'iso' );
    }

    # if ceilingDueDate ON the datedue can't be after the ceiling date
    if ( C4::Context->preference('ceilingDueDate')
             && ( C4::Context->preference('ceilingDueDate') =~ C4::Dates->regexp('syspref') ) ) {
            my $ceilingDate = C4::Dates->new( C4::Context->preference('ceilingDueDate') );
            if ( $datedue->output( 'iso' ) gt $ceilingDate->output( 'iso' ) ) {
                $datedue = $ceilingDate;
            }
    }

    return $datedue;
}

=head2 CheckValidDatedue
       This function does not account for holiday exceptions nor does it handle the 'useDaysMode' syspref .
       To be replaced by CalcDateDue() once C4::Calendar use is tested.

$newdatedue = CheckValidDatedue($date_due,$itemnumber,$branchcode);
this function validates the loan length against the holidays calendar, and adjusts the due date as per the 'useDaysMode' syspref.
C<$date_due>   = returndate calculate with no day check
C<$itemnumber>  = itemnumber
C<$branchcode>  = location of issue (affected by 'CircControl' syspref)
C<$loanlength>  = loan length prior to adjustment
=cut

sub CheckValidDatedue {
my ($date_due,$itemnumber,$branchcode)=@_;
my @datedue=split('-',$date_due->output('iso'));
my $years=$datedue[0];
my $month=$datedue[1];
my $day=$datedue[2];
# die "Item# $itemnumber ($branchcode) due: " . ${date_due}->output() . "\n(Y,M,D) = ($years,$month,$day)":
my $dow;
for (my $i=0;$i<2;$i++){
    $dow=Day_of_Week($years,$month,$day);
    ($dow=0) if ($dow>6);
    my $result=CheckRepeatableHolidays($itemnumber,$dow,$branchcode);
    my $countspecial=CheckSpecialHolidays($years,$month,$day,$itemnumber,$branchcode);
    my $countspecialrepeatable=CheckRepeatableSpecialHolidays($month,$day,$itemnumber,$branchcode);
        if (($result ne '0') or ($countspecial ne '0') or ($countspecialrepeatable ne '0') ){
        $i=0;
        (($years,$month,$day) = Add_Delta_Days($years,$month,$day, 1))if ($i ne '1');
        }
    }
    my $newdatedue=C4::Dates->new(sprintf("%04d-%02d-%02d",$years,$month,$day),'iso');
return $newdatedue;
}


=head2 CheckRepeatableHolidays

$countrepeatable = CheckRepeatableHoliday($itemnumber,$week_day,$branchcode);
this function checks if the date due is a repeatable holiday
C<$date_due>   = returndate calculate with no day check
C<$itemnumber>  = itemnumber
C<$branchcode>  = localisation of issue 

=cut

sub CheckRepeatableHolidays{
my($itemnumber,$week_day,$branchcode)=@_;
my $dbh = C4::Context->dbh;
my $query = qq|SELECT count(*)  
    FROM repeatable_holidays 
    WHERE branchcode=?
    AND weekday=?|;
my $sth = $dbh->prepare($query);
$sth->execute($branchcode,$week_day);
my $result=$sth->fetchrow;
$sth->finish;
return $result;
}


=head2 CheckSpecialHolidays

$countspecial = CheckSpecialHolidays($years,$month,$day,$itemnumber,$branchcode);
this function check if the date is a special holiday
C<$years>   = the years of datedue
C<$month>   = the month of datedue
C<$day>     = the day of datedue
C<$itemnumber>  = itemnumber
C<$branchcode>  = localisation of issue 

=cut

sub CheckSpecialHolidays{
my ($years,$month,$day,$itemnumber,$branchcode) = @_;
my $dbh = C4::Context->dbh;
my $query=qq|SELECT count(*) 
         FROM `special_holidays`
         WHERE year=?
         AND month=?
         AND day=?
             AND branchcode=?
        |;
my $sth = $dbh->prepare($query);
$sth->execute($years,$month,$day,$branchcode);
my $countspecial=$sth->fetchrow ;
$sth->finish;
return $countspecial;
}

=head2 CheckRepeatableSpecialHolidays

$countspecial = CheckRepeatableSpecialHolidays($month,$day,$itemnumber,$branchcode);
this function check if the date is a repeatble special holidays
C<$month>   = the month of datedue
C<$day>     = the day of datedue
C<$itemnumber>  = itemnumber
C<$branchcode>  = localisation of issue 

=cut

sub CheckRepeatableSpecialHolidays{
my ($month,$day,$itemnumber,$branchcode) = @_;
my $dbh = C4::Context->dbh;
my $query=qq|SELECT count(*) 
         FROM `repeatable_holidays`
         WHERE month=?
         AND day=?
             AND branchcode=?
        |;
my $sth = $dbh->prepare($query);
$sth->execute($month,$day,$branchcode);
my $countspecial=$sth->fetchrow ;
$sth->finish;
return $countspecial;
}



sub CheckValidBarcode{
my ($barcode) = @_;
my $dbh = C4::Context->dbh;
my $query=qq|SELECT count(*) 
         FROM items 
             WHERE barcode=?
        |;
my $sth = $dbh->prepare($query);
$sth->execute($barcode);
my $exist=$sth->fetchrow ;
$sth->finish;
return $exist;
}

=head2 IsBranchTransferAllowed

$allowed = IsBranchTransferAllowed( $toBranch, $fromBranch, $code );

Code is either an itemtype or collection doe depending on the pref BranchTransferLimitsType

=cut

sub IsBranchTransferAllowed {
    my ( $toBranch, $fromBranch, $code ) = @_;

    if ( $toBranch eq $fromBranch ) { return 1; } ## Short circuit for speed.
        
    my $limitType = C4::Context->preference("BranchTransferLimitsType");   
    my $dbh = C4::Context->dbh;
            
    my $sth = $dbh->prepare("SELECT * FROM branch_transfer_limits WHERE toBranch = ? AND fromBranch = ? AND $limitType = ?");
    $sth->execute( $toBranch, $fromBranch, $code );
    my $limit = $sth->fetchrow_hashref();
                        
    ## If a row is found, then that combination is not allowed, if no matching row is found, then the combination *is allowed*
    if ( $limit->{'limitId'} ) {
        return 0;
    } else {
        return 1;
    }
}                                                        

=head2 CreateBranchTransferLimit

CreateBranchTransferLimit( $toBranch, $fromBranch, $code );

$code is either itemtype or collection code depending on what the pref BranchTransferLimitsType is set to.

=cut

sub CreateBranchTransferLimit {
   my ( $toBranch, $fromBranch, $code ) = @_;

   my $limitType = C4::Context->preference("BranchTransferLimitsType");
   
   my $dbh = C4::Context->dbh;
   
   my $sth = $dbh->prepare("INSERT INTO branch_transfer_limits ( $limitType, toBranch, fromBranch ) VALUES ( ?, ?, ? )");
   $sth->execute( $code, $toBranch, $fromBranch );
}

=head2 DeleteBranchTransferLimits

DeleteBranchTransferLimits();

=cut

sub DeleteBranchTransferLimits {
   my $dbh = C4::Context->dbh;
   my $sth = $dbh->prepare("TRUNCATE TABLE branch_transfer_limits");
   $sth->execute();
}

### Returns arrayref of branchcodes which possess the given bib's
### items and having that item sitting on the shelf available for
### checkout.
sub BiblioIsAvailableAt {
    my $biblionumber = shift;
    my @branches;
    for my $itemref ( @{C4::Items::GetBiblioItems($biblionumber)} ) {
        my $item = GetItem($itemref->{itemnumber});
        push @branches, $item if ItemIsAvailable($item);
    }
    return [map { $_->{homebranch} } @branches];
}

### Returns true if item is on the shelf available for checkout in a
### general sense. Does *not* make any reference to circulation rules
### or anything specific to a given patron.
sub ItemIsAvailable {
    my ($item) = @_;

    my $status_check = !$item->{onloan}
        && !$item->{wthdrawn}
        && !$item->{itemlost}
        && !$item->{damaged}
        && !$item->{notforloan};
    return unless $status_check;
    return if C4::Circulation::GetTransfers( $item->{itemnumber} );
    return if C4::Reserves::GetReservesFromItemnumber( $item->{itemnumber} );

    return 1;
}

  1;

__END__

=head1 AUTHOR

Koha Developement team <info@koha.org>

=cut

