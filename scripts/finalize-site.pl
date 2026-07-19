#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use File::Basename qw(dirname);
use File::Find;
use File::Path qw(make_path);

my $root = shift @ARGV // 'www';
die "Site root does not exist: $root\n" unless -d $root;

my %aliases = (
  '/smart_office/' => '/smart_office_in_moscow/',
  '/price/' => '/price_coworking_rent/',
  '/price_coworking/' => '/price_coworking_rent/',
  '/accounting_service/' => '/accounting_services/',
  '/workplaces/' => '/landing_workplaces/',
  '/about_/' => '/about_company/',
  '/1/' => '/',
  '/accounting_services_100_3/' => '/simplified_accounting_services_100_3/',
  '/accounting_services_150_5/' => '/simplified_accounting_services_150_5/',
  '/accounting_services_300_10/' => '/simplified_accounting_services_300_10/',
  '/universal/' => '/accounting_services/',
  '/contract_offer_coworking/' => '/price_coworking_rent/',
  '/cloud_storage/' => '/it_outsourcing/',
  '/negotiation_rooms_30/' => '/conference_rooms/',
);

my @product_routes = (
  '/price/tproduct/180275711-480090937179-zakreplennoe-rabochee-mesto-dlya-dvoih-s',
  '/price/tproduct/180275711-389916412892-uslovno-zakreplennoe-rabochee-mesto-srok',
  '/price/tproduct/181105198-672372631258-vechernee-i-vihodnoe-svobodnoe-rabochee',
  '/price/tproduct/181105198-306382424236-svobodnoe-rabochee-mesto-srokom-na-dva-m',
  '/price/tproduct/186244571-914852946555-godovoi-abonement-na-30-chasov-dostupa-v',
  '/price/tproduct/180275711-727476348720-zakreplennoe-rabochee-mesto-na-dvoih-s-k',
  '/price/tproduct/181105198-608570613508-svobodnoe-rabochee-mesto-srokom-na-tri-m',
  '/price/tproduct/186257806-130598540909-arenda-peregovornoi-komnati-na-chas-ot-9',
  '/price/tproduct/186257806-933411613265-arenda-peregovornoi-komnati-na-chas-ot-1',
  '/price/tproduct/186244571-592074671335-godovoi-abonement-dostupa-v-kovorking-na',
  '/price_coworking/tproduct/192468506-306382424236-svobodnoe-rabochee-mesto-srokom-na-mesya',
  '/price_coworking/tproduct/192468506-608570613508-svobodnoe-rabochee-mesto-na-10-rabdnei-v',
);

my @virtual_product_routes = (
  '/price_virtual_office/tproduct/194496622-290633839565-udalennii-pomoschnik-sekretar-na-120-min',
  '/price_virtual_office/tproduct/194496622-277276310165-udalennii-pomoschnik-sekretar-na-240-min',
  '/price_virtual_office/tproduct/194496622-532609592040-udalennii-pomoschnik-sekretar-na-480-min',
  '/price_virtual_office/tproduct/194496622-680918901589-udalennii-pomoschnik-sekretar-na-1000-mi',
  '/price_virtual_office/tproduct/194496622-749853681425-udalennii-pomoschnik-sekretar-na-2000-mi',
);

$aliases{"$_/"} = '/price_coworking_rent/' for @product_routes;
$aliases{"$_/"} = '/price_virtual_office/' for @virtual_product_routes;

sub slurp {
  my ($path) = @_;
  open(my $fh, '<:raw', $path) or die "Cannot read $path: $!";
  local $/;
  my $text = <$fh>;
  close($fh);
  return $text;
}

sub write_file {
  my ($path, $text) = @_;
  make_path(dirname($path));
  open(my $fh, '>:raw', $path) or die "Cannot write $path: $!";
  print {$fh} $text;
  close($fh);
}

my @html_files;
find(
  sub {
    push @html_files, $File::Find::name if -f $_ && /\.html$/i;
  },
  $root,
);

for my $path (@html_files) {
  my $html = slurp($path);
  $html =~ s{<link\b[^>]*\brel=(["'])(?:dns-prefetch|preconnect)\1[^>]*>}{}gsi;
  $html =~ s{(\bcontent=["'][^"']+\.(?:jpe?g|png|webp|gif|svg))\}}{$1}gsi;
  $html =~ s{/(_external/static\.tildacdn\.com/38af5ec3-9816-4508-bfa4-42b757792179/photo1442406964439e46ab8eff7c4)/}{/$1}g;
  $html =~ s{(/_external/static\.tildacdn\.com/js/tilda-(?:forms|cart)-1\.0\.min\.js)(?:\?local=\d+)?}{$1?local=20260719}g;
  $html =~ s{<script\b[^>]*>\s*if \(! window\.mainTracker\)(?:(?!</script>).)*</script>}{}gsi;
  $html =~ s{(<link\b[^>]*\brel=["']canonical["'][^>]*\bhref=["'])/}{$1https://office24-7.ru/}gsi;
  $html =~ s{(<meta\b[^>]*\bproperty=["']og:url["'][^>]*\bcontent=["'])/}{$1https://office24-7.ru/}gsi;
  $html =~ s{(<meta\b[^>]*\bproperty=["']og:image["'][^>]*\bcontent=["'])/}{$1https://office24-7.ru/}gsi;
  write_file($path, $html);
}

for my $route (sort keys %aliases) {
  my $target = $aliases{$route};
  my $relative = $route;
  $relative =~ s{^/}{};
  my $path = "$root/$relative/index.html";
  my $escaped_target = $target;
  $escaped_target =~ s/&/&amp;/g;
  $escaped_target =~ s/"/&quot;/g;
  my $js_target = $target;
  $js_target =~ s/'/\\'/g;
  my $html = qq{<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="0;url=$escaped_target"><link rel="canonical" href="$escaped_target"><title>Redirecting</title></head><body><p><a href="$escaped_target">Open the current page</a></p><script>location.replace('$js_target');</script></body></html>};
  write_file($path, $html);
}

my $feed_js = "$root/_external/static.tildacdn.com/js/tilda-feed-1.0.min.js";
if (-f $feed_js) {
  my $js = slurp($feed_js);
  $js =~ s{_="https://"\+window\.t_feeds_endpoint\+"/api/getfeed/"}{_="/api/getfeed/"}g;
  write_file($feed_js, $js);
}

# Tilda's local form and cart bundles dynamically inject these helpers. Keep
# those late-loaded scripts on the archived origin as well.
my %dynamic_script_rewrites = (
  "$root/_external/static.tildacdn.com/js/tilda-forms-1.0.min.js" => [
    ['"https://static.tildacdn."+t_forms__getRootZone()+"/js/"+s+".min.js"', '"/_external/static.tildacdn.com/js/"+s+".min.js"'],
    ['"https://static.tildacdn."+t_forms__getRootZone()+"/js/tilda-forms-custommask-1.0.min.js"', '"/_external/static.tildacdn.com/js/tilda-forms-custommask-1.0.min.js"'],
  ],
  "$root/_external/static.tildacdn.com/js/tilda-cart-1.0.min.js" => [
    ['"https://static.tildacdn."+tcart__getRootZone()+"/js/tilda-widget-positions-1.0.min.js"', '"/_external/static.tildacdn.com/js/tilda-widget-positions-1.0.min.js"'],
  ],
);

for my $path (sort keys %dynamic_script_rewrites) {
  next unless -f $path;
  my $js = slurp($path);
  for my $rewrite (@{$dynamic_script_rewrites{$path}}) {
    my ($from, $to) = @{$rewrite};
    $js =~ s/\Q$from\E/$to/g;
  }
  write_file($path, $js);
}

my $report = "route\ttarget\n";
$report .= "$_\t$aliases{$_}\n" for sort keys %aliases;
write_file('reports/aliases.tsv', $report);

print "Finalized " . scalar(@html_files) . " HTML files and created " . scalar(keys %aliases) . " compatibility routes.\n";
