
<h1 id="logo"><a href="/cgi-bin/koha/mainpage.pl"><!-- TMPL_VAR NAME="LibraryName" --></a></h1><!-- Begin Checkin Resident Search Box -->
<div id="header_search" class="tabs-bottom">
<ul>
    <!-- TMPL_IF NAME="CAN_user_circulate" --><li><a href="#tabs-circ_search">Check Out</a></li><!-- /TMPL_IF -->
    <!-- TMPL_IF NAME="CAN_user_catalogue" --><li><a href="#tabs-catalog_search">Search the Catalog</a></li><!-- /TMPL_IF -->
</ul>   
<!-- TMPL_INCLUDE NAME="patron-search-box.inc" -->
<!-- TMPL_IF NAME="CAN_user_catalogue" -->
<div id="tabs-catalog_search" class="residentsearch">
    <p class="tip">Enter search keywords:</p>
    <form action="/cgi-bin/koha/catalogue/search.pl"  method="get" id="cat-search-block">
        <input type="text" name="q" id="search-form" size="40" />
        <input type="submit" class="submit" value="Submit"/>
    </form>
</div>
<!-- /TMPL_IF -->

</div>

<!-- End Checkin Resident Search Box -->
