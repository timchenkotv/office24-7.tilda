#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use URI;
use URI::Escape qw(uri_unescape);
use Digest::SHA qw(sha1_hex);
use JSON::PP;
use Encode qw(decode);

my $ROOT = 'https://office24-7.ru/';
my $ROOT_HOST = 'office24-7.ru';
my $BASE_DIR = $ENV{MIRROR_BASE_DIR} // '.';
my $OUT_DIR = "$BASE_DIR/www";
my $WORK_DIR = "$BASE_DIR/.mirror-work";
my $REPORT_DIR = "$BASE_DIR/reports";
my $LOG_DIR = "$WORK_DIR/logs";
my $COOKIE = "$WORK_DIR/cookies.txt";
my $UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X) CodexMirror/1.0';

my $MAX_PAGES = 7000;
my $MAX_ASSETS = 30000;

make_path($OUT_DIR, $WORK_DIR, $REPORT_DIR, $LOG_DIR);
open(my $cookie_fh, '>>', $COOKIE) or die "Cannot init cookie jar: $!";
close($cookie_fh);

my (%page_seen, @page_queue);
my (%asset_seen, @asset_queue);
my (%downloaded, @files_meta);
my (@fetch_failures, %sitemap_pages);
my (%cache_map);

if (defined $ENV{MIRROR_CACHE_MAP} && -f $ENV{MIRROR_CACHE_MAP}) {
  open(my $cache_fh, '<:raw', $ENV{MIRROR_CACHE_MAP}) or die "Cannot read cache map: $!";
  while (my $line = <$cache_fh>) {
    chomp $line;
    my ($url, $path) = split(/\t/, $line, 2);
    $cache_map{$url} = $path if defined $url && defined $path;
  }
  close($cache_fh);
}

sub log_msg {
  my ($msg) = @_;
  print "$msg\n";
}

sub trim {
  my ($s) = @_;
  $s //= '';
  $s =~ s/^\s+//;
  $s =~ s/\s+$//;
  return $s;
}

sub canon_url {
  my ($raw, $base) = @_;
  return undef unless defined $raw;
  $raw = trim($raw);
  return undef if $raw eq '';
  return undef if $raw =~ m{^(#|javascript:|mailto:|tel:|data:)}i;
  return undef if $raw =~ /[\\\x00-\x1f]/;

  my $u;
  eval {
    $u = defined($base) ? URI->new_abs($raw, $base) : URI->new($raw);
  };
  return undef if $@ || !$u;

  my $scheme = lc($u->scheme // '');
  return undef unless $scheme eq 'http' || $scheme eq 'https';

  $u->fragment(undef);
  my $host = lc($u->host // '');
  $host = $ROOT_HOST if $host eq "www.$ROOT_HOST";
  $u->host($host) if $host ne '';

  return $u->as_string;
}

sub has_page_ext {
  my ($path) = @_;
  return 1 if $path =~ /\.(html?|php|asp|aspx)$/i;
  return 0;
}

sub has_any_ext {
  my ($path) = @_;
  return $path =~ /\.[A-Za-z0-9]{1,8}$/ ? 1 : 0;
}

sub is_page_url {
  my ($u_str) = @_;
  my $u = URI->new($u_str);
  my $path = $u->path // '/';
  return 1 if $path eq '' || $path eq '/';
  return 1 if $path =~ /\/$/;
  return 1 if has_page_ext($path);
  return 1 if !has_any_ext($path);
  return 0;
}

sub is_primary_host {
  my ($host) = @_;
  $host = lc($host // '');
  return 1 if $host eq $ROOT_HOST;
  return 1 if $host eq "www.$ROOT_HOST";
  return 1 if $host =~ /\.\Q$ROOT_HOST\E$/;
  return 0;
}

sub is_allowed_asset_host {
  my ($host) = @_;
  $host = lc($host // '');
  return 1 if is_primary_host($host);
  return 1 if $host =~ /(^|\.)tildacdn\.(com|net|info)$/;
  return 1 if $host =~ /(^|\.)tilda\.ws$/;
  return 1 if $host =~ /^fonts\.(googleapis|gstatic)\.com$/;
  return 0;
}

sub sanitize_seg {
  my ($s) = @_;
  $s = uri_unescape($s // '');
  $s =~ s/[\\:*?"<>|]/_/g;
  $s =~ s/\s+/ /g;
  $s =~ s/^\s+|\s+$//g;
  return $s;
}

sub hash_short {
  my ($s) = @_;
  return substr(sha1_hex($s // ''), 0, 10);
}

sub to_local_webpath {
  my ($u_str, $kind) = @_;
  my $u = URI->new($u_str);
  my $host = lc($u->host // '');
  my $path = $u->path // '/';
  my @parts = map { sanitize_seg($_) } grep { length($_) } split('/', $path);

  my $is_page = ($kind // '') eq 'page';
  if (!$is_page && $host eq $ROOT_HOST && is_page_url($u_str)) {
    $is_page = 1;
  }

  my (@dir, $filename);
  if ($path eq '' || $path eq '/') {
    @dir = ();
    $filename = 'index.html';
  } elsif ($path =~ /\/$/) {
    @dir = @parts;
    $filename = $is_page ? 'index.html' : 'index.bin';
  } elsif ($is_page && !has_any_ext($path)) {
    @dir = @parts;
    $filename = 'index.html';
  } else {
    @dir = @parts[0 .. $#parts-1] if @parts > 1;
    $filename = @parts ? $parts[-1] : 'index.bin';
  }

  my $q = $u->query // '';
  if ($q ne '') {
    if ($filename =~ /^(.*?)(\.[^.]*)$/) {
      $filename = $1 . '__q_' . hash_short($q) . $2;
    } else {
      $filename .= '__q_' . hash_short($q);
    }
  }

  my @base = ($host eq $ROOT_HOST) ? () : ('_external', $host);
  my @all = grep { length($_) } (@base, @dir, $filename);
  return '/' . join('/', @all);
}

sub to_disk_path {
  my ($web_path) = @_;
  $web_path =~ s#^/##;
  return "$OUT_DIR/$web_path";
}

sub pretty_page_link {
  my ($web_path) = @_;
  return $web_path unless $web_path =~ /\.html$/i;
  return '/' if $web_path eq '/index.html';
  if ($web_path =~ m#^(.*)/index\.html$#i) {
    my $p = $1;
    $p = '/' if $p eq '';
    return $p . '/';
  }
  return $web_path;
}

sub fetch_to_file {
  my ($url, $out_file) = @_;
  make_path(dirname($out_file));

  if (defined $ENV{MIRROR_CACHE_ROOT} && exists $cache_map{$url}) {
    my $rel = $cache_map{$url};
    $rel =~ s#^/##;
    my $cached = "$ENV{MIRROR_CACHE_ROOT}/$rel";
    if (-f $cached && $cached !~ /\.(?:html?|css|js|json|xml)$/i) {
      copy($cached, $out_file) or die "Cannot copy cached asset $cached: $!";
      my $ctype = 'application/octet-stream';
      $ctype = 'image/jpeg' if $cached =~ /\.(?:jpe?g)$/i;
      $ctype = 'image/png' if $cached =~ /\.png$/i;
      $ctype = 'image/webp' if $cached =~ /\.webp$/i;
      $ctype = 'image/svg+xml' if $cached =~ /\.svg$/i;
      $ctype = 'image/gif' if $cached =~ /\.gif$/i;
      $ctype = 'font/woff2' if $cached =~ /\.woff2$/i;
      $ctype = 'font/woff' if $cached =~ /\.woff$/i;
      return (1, $url, $ctype, 200);
    }
  }

  my @cmd = (
    'curl', '-sSL', '-A', $UA,
    '--compressed',
    '--retry', '3', '--retry-delay', '1', '--retry-all-errors',
    '-b', $COOKIE, '-c', $COOKIE,
    '--max-time', '35',
    '-o', $out_file,
    '-w', "%{http_code}\t%{url_effective}\t%{content_type}",
    $url,
  );

  my $meta = '';
  open(my $ph, '-|', @cmd) or return (0, '', '', 0);
  { local $/; $meta = <$ph> // ''; }
  close($ph);

  my ($code, $effective, $ctype) = split(/\t/, trim($meta), 3);
  $code //= 0;
  $effective //= $url;
  $ctype //= '';

  my $ok = ($code =~ /^\d+$/ && $code >= 200 && $code < 400 && -s $out_file) ? 1 : 0;
  return ($ok, $effective, lc($ctype // ''), int($code || 0));
}

sub slurp {
  my ($f) = @_;
  open(my $fh, '<:raw', $f) or return undef;
  local $/;
  my $c = <$fh>;
  close($fh);
  return $c;
}

sub write_file {
  my ($f, $content) = @_;
  make_path(dirname($f));
  open(my $fh, '>:raw', $f) or die "Cannot write $f: $!";
  print {$fh} $content;
  close($fh);
}

sub extract_locs {
  my ($xml) = @_;
  my @out;
  while ($xml =~ m{<loc>([\s\S]*?)</loc>}gi) {
    my $v = trim($1);
    $v =~ s/&amp;/&/g;
    $v =~ s/&lt;/</g;
    $v =~ s/&gt;/>/g;
    $v =~ s/&quot;/"/g;
    $v =~ s/&#39;/'/g;
    push @out, $v if $v ne '';
  }
  return @out;
}

sub extract_urls_from_html {
  my ($html) = @_;
  my @out;

  while ($html =~ /\b(href|src|poster|data-src|data-original|data-img-zoom-url|data-content-cover-bg|data-bg|data-lazy-src)\s*=\s*(["'])(.*?)\2/gsi) {
    my $attr = lc($1);
    my $u = trim($3);
    push @out, [$attr, $u] if $u ne '';
  }

  while ($html =~ /\bsrcset\s*=\s*(["'])(.*?)\1/gsi) {
    my $set = $2 // '';
    my @items = split(/,/, $set);
    for my $it (@items) {
      $it = trim($it);
      my ($u) = split(/\s+/, $it, 2);
      push @out, ['srcset', $u] if defined $u && $u ne '';
    }
  }

  while ($html =~ /url\(([^\)]+)\)/gsi) {
    my $u = trim($1);
    $u =~ s/^['"]|['"]$//g;
    push @out, ['style', $u] if $u ne '';
  }

  while ($html =~ /<meta\b[^>]*(?:property|name)\s*=\s*(["'])[^"']*(?:image|icon)[^"']*\1[^>]*>/gsi) {
    my $tag = $&;
    if ($tag =~ /\bcontent\s*=\s*(["'])(.*?)\1/gsi) {
      my $u = trim($2);
      push @out, ['content', $u] if $u ne '';
    }
  }

  while ($html =~ m{https?://[^\s"'<>\\]+}gsi) {
    my $u = trim($&);
    $u =~ s/[),;]+$//;
    push @out, ['embedded', $u] if $u ne '';
  }

  return @out;
}

sub extract_urls_from_css {
  my ($css) = @_;
  my @out;

  while ($css =~ /\@import\s+(?:url\()?['"]?([^'"\)\s]+)['"]?\)?/gsi) {
    my $u = trim($1);
    push @out, $u if $u ne '';
  }

  while ($css =~ /url\(([^\)]+)\)/gsi) {
    my $u = trim($1);
    $u =~ s/^['"]|['"]$//g;
    push @out, $u if $u ne '';
  }

  return @out;
}

sub enqueue_page {
  my ($u) = @_;
  return if !$u;
  my $obj = URI->new($u);
  return unless is_primary_host($obj->host // '');
  return if $page_seen{$u};
  return if @page_queue + scalar(keys %page_seen) >= $MAX_PAGES;
  push @page_queue, $u;
}

sub enqueue_asset {
  my ($u) = @_;
  return if !$u;
  my $obj = URI->new($u);
  return unless is_allowed_asset_host($obj->host // '');
  return if $asset_seen{$u};
  return if @asset_queue + scalar(keys %asset_seen) >= $MAX_ASSETS;
  push @asset_queue, $u;
}

sub load_sitemaps {
  my @sm_q = ('https://office24-7.ru/sitemap.xml');
  my %sm_seen;

  while (@sm_q) {
    my $sm = shift @sm_q;
    next if $sm_seen{$sm}++;

    my $tmp = "$WORK_DIR/sm_" . hash_short($sm) . ".xml";
    my ($ok) = fetch_to_file($sm, $tmp);
    next unless $ok;

    my $xml = slurp($tmp);
    next unless defined $xml;

    for my $loc (extract_locs($xml)) {
      my $u = canon_url($loc);
      next unless $u;
      my $obj = URI->new($u);
      next unless lc($obj->host // '') eq $ROOT_HOST;

      my $path = lc($obj->path // '');
      if ($path =~ /\.xml$/ || $path =~ /sitemap/) {
        push @sm_q, $u;
      } else {
        $sitemap_pages{$u} = 1;
        enqueue_page($u);
      }
    }
  }

  enqueue_page('https://office24-7.ru/') unless @page_queue;
}

sub crawl_pages {
  while (@page_queue) {
    my $url = shift @page_queue;
    next if $page_seen{$url}++;

    my $tmp = "$WORK_DIR/page_" . hash_short($url) . ".tmp";
    my ($ok, $eff, $ct, $code) = fetch_to_file($url, $tmp);
    if (!$ok) {
      push @fetch_failures, { type => 'page', url => $url, code => $code };
      next;
    }

    my $final = canon_url($eff) // $url;
    my $web = to_local_webpath($final, 'page');
    my $dst = to_disk_path($web);
    my $bytes = slurp($tmp);
    next unless defined $bytes;

    write_file($dst, $bytes);
    $downloaded{$url} = $web;
    $downloaded{$final} = $web;
    push @files_meta, { file => $dst, url => $final, type => 'html' };

    my $text = eval { decode('UTF-8', $bytes, 1) };
    if (!defined $text) {
      $text = $bytes;
    }

    for my $ref (extract_urls_from_html($text)) {
      my ($attr, $raw) = @$ref;
      my $abs = canon_url($raw, $final);
      next unless $abs;

      my $u = URI->new($abs);
      my $host = lc($u->host // '');
      if (is_primary_host($host) && $attr eq 'href' && is_page_url($abs)) {
        enqueue_page($abs);
      } else {
        my $path = $u->path // '';
        my $has_query = defined($u->query) && $u->query ne '';
        my $is_resource_attr = $attr ne 'href' && $attr ne 'embedded';
        if (is_allowed_asset_host($host) && (has_any_ext($path) || $has_query || $is_resource_attr)) {
          enqueue_asset($abs);
        }
      }
    }

    if ($ct !~ m{text/html}i) {
      enqueue_asset($final);
    }

    unlink $tmp;
  }
}

sub crawl_assets {
  while (@asset_queue) {
    my $url = shift @asset_queue;
    next if $asset_seen{$url}++;

    my $tmp = "$WORK_DIR/asset_" . hash_short($url) . ".tmp";
    my ($ok, $eff, $ct, $code) = fetch_to_file($url, $tmp);
    if (!$ok) {
      push @fetch_failures, { type => 'asset', url => $url, code => $code };
      my $path = URI->new($url)->path // '';
      if ($code == 404 && $path =~ /\.css$/i) {
        my $web = to_local_webpath($url, 'asset');
        my $dst = to_disk_path($web);
        write_file($dst, "/* The source stylesheet returned 404 during export. */\n");
        $downloaded{$url} = $web;
        push @files_meta, { file => $dst, url => $url, type => 'css' };
      }
      next;
    }

    my $final = canon_url($eff) // $url;

    my $kind = ($ct =~ m{text/html}i && is_page_url($final)) ? 'page' : 'asset';
    my $web = to_local_webpath($final, $kind);
    if ($kind ne 'page' && $web !~ /\.[A-Za-z0-9]{1,8}$/) {
      $web .= '.css' if $ct =~ m{text/css}i;
      $web .= '.js' if $ct =~ m{(?:javascript|ecmascript)}i;
      $web .= '.woff2' if $ct =~ m{font/woff2}i;
      $web .= '.woff' if $ct =~ m{font/woff(?:;|$)}i;
    }
    my $dst = to_disk_path($web);

    my $bytes = slurp($tmp);
    next unless defined $bytes;

    if ($ct =~ m{text/css}i || $final =~ /\.css(?:$|\?)/i) {
      my $css = $bytes;
      for my $raw (extract_urls_from_css($css)) {
        my $abs = canon_url($raw, $final);
        enqueue_asset($abs) if $abs;
      }
      push @files_meta, { file => $dst, url => $final, type => 'css' };
    } elsif ($kind eq 'page') {
      push @files_meta, { file => $dst, url => $final, type => 'html' };
    } else {
      push @files_meta, { file => $dst, url => $final, type => 'asset' };
    }

    write_file($dst, $bytes);
    $downloaded{$url} = $web;
    $downloaded{$final} = $web;
    unlink $tmp;
  }
}

sub resolve_local_link {
  my ($raw, $from) = @_;
  my $abs = canon_url($raw, $from);
  return undef unless $abs;

  if (exists $downloaded{$abs}) {
    my $w = $downloaded{$abs};
    return is_page_url($abs) ? pretty_page_link($w) : $w;
  }

  my $u = URI->new($abs);
  my $host = lc($u->host // '');
  if (is_primary_host($host)) {
    my $w = to_local_webpath($abs, is_page_url($abs) ? 'page' : 'asset');
    return is_page_url($abs) ? pretty_page_link($w) : $w;
  }

  return undef;
}

sub rewrite_exact_downloaded {
  my ($text) = @_;
  for my $source (sort { length($b) <=> length($a) } keys %downloaded) {
    my $target = $downloaded{$source};
    $target = pretty_page_link($target) if is_page_url($source);
    $text =~ s/\Q$source\E/$target/g;

    my $escaped = $source;
    $escaped =~ s/&/&amp;/g;
    $text =~ s/\Q$escaped\E/$target/g if $escaped ne $source;
  }
  return $text;
}

sub rewrite_one_text {
  my ($text, $from_url, $is_css) = @_;

  $text =~ s{(\bhref\s*=\s*["'])\\+}{$1/}gsi;

  $text =~ s{\b(?:href|src|poster|data-src|data-original|data-img-zoom-url|data-content-cover-bg|data-bg|data-lazy-src)\s*=\s*(["'])(.*?)\1}{
    my $all = $&;
    my $raw = $2;
    my $next = resolve_local_link($raw, $from_url);
    defined($next) ? ($all =~ s/\Q$raw\E/$next/r) : $all;
  }egsi;

  $text =~ s{\bsrcset\s*=\s*(["'])(.*?)\1}{
    my $q = $1;
    my $val = $2;
    my @items = split(/,/, $val);
    for my $it (@items) {
      my $trim = trim($it);
      my ($u, $rest) = split(/\s+/, $trim, 2);
      next unless defined $u;
      my $next = resolve_local_link($u, $from_url);
      if (defined $next) {
        $it = defined($rest) ? "$next $rest" : $next;
      }
    }
    'srcset=' . $q . join(', ', @items) . $q;
  }egsi;

  $text =~ s{url\(([^\)]+)\)}{
    my $raw = trim($1);
    $raw =~ s/^['"]|['"]$//g;
    my $next = resolve_local_link($raw, $from_url);
    defined($next) ? "url($next)" : $&;
  }egsi;

  if ($is_css) {
    $text =~ s{\@import\s+(?:url\()?['"]?([^'"\)\s]+)['"]?\)?}{
      my $raw = $1;
      my $next = resolve_local_link($raw, $from_url);
      defined($next) ? ($& =~ s/\Q$raw\E/$next/r) : $&;
    }egsi;
  }

  $text = rewrite_exact_downloaded($text);

  $text =~ s{https?://office24-7.ru/}{/}gi;
  return $text;
}

sub rewrite_downloaded {
  for my $m (@files_meta) {
    next unless $m->{type} eq 'html' || $m->{type} eq 'css';
    my $raw = slurp($m->{file});
    next unless defined $raw;

    my $text = $raw;
    my $next;
    if ($m->{type} eq 'html') {
      my @scripts;
      $text =~ s{<script\b[\s\S]*?</script>}{
        my $index = scalar @scripts;
        push @scripts, $&;
        "<!--OFFICE24_SCRIPT_$index-->";
      }egsi;

      $next = rewrite_one_text($text, $m->{url}, 0);
      for my $index (0 .. $#scripts) {
        my $script = rewrite_exact_downloaded($scripts[$index]);
        my $marker = "<!--OFFICE24_SCRIPT_$index-->";
        $next =~ s/\Q$marker\E/$script/;
      }
    } else {
      $next = rewrite_one_text($text, $m->{url}, 1);
    }
    if ($m->{type} eq 'html' && $next !~ /office24-static-form-guard/) {
      my $guard = q{<script id="office24-static-form-guard">document.addEventListener('submit',function(e){e.preventDefault();e.stopImmediatePropagation();},true);</script>};
      if ($next =~ m{</body>}i) {
        $next =~ s{</body>}{$guard</body>}i;
      } else {
        $next .= $guard;
      }
    }
    write_file($m->{file}, $next) if $next ne $text;
  }
}

sub local_target_from_link {
  my ($link) = @_;
  return undef if !defined $link || $link eq '';
  return undef unless $link =~ m{^/};

  my $p = $link;
  $p =~ s/[#?].*$//;
  $p = '/' if $p eq '';

  if ($p =~ m{/$}) {
    $p .= 'index.html';
  } elsif ($p !~ /\.[A-Za-z0-9]{1,8}$/) {
    $p .= '/index.html';
  }

  return to_disk_path($p);
}

sub check_broken_links {
  my @missing;

  for my $m (@files_meta) {
    next unless $m->{type} eq 'html';
    my $raw = slurp($m->{file});
    next unless defined $raw;
    my $html = $raw;

    my @links;
    while ($html =~ /\b(?:href|src|poster|data-src|data-original|data-img-zoom-url|data-content-cover-bg|data-bg|data-lazy-src)\s*=\s*(["'])(.*?)\1/gsi) {
      my $u = trim($2);
      push @links, $u if $u =~ m{^/};
    }

    while ($html =~ /\bsrcset\s*=\s*(["'])(.*?)\1/gsi) {
      my $set = $2 // '';
      for my $it (split(/,/, $set)) {
        my ($u) = split(/\s+/, trim($it), 2);
        push @links, $u if defined($u) && $u =~ m{^/};
      }
    }

    for my $l (@links) {
      my $target = local_target_from_link($l);
      next unless defined $target;
      if (!-e $target) {
        push @missing, [$m->{file}, $l, $target];
      }
    }
  }

  return @missing;
}

sub write_reports {
  my @missing = check_broken_links();

  my $summary = {
    generated_at => scalar gmtime() . ' UTC',
    root => $ROOT,
    pages_seen => scalar(keys %page_seen),
    assets_seen => scalar(keys %asset_seen),
    files_written => scalar(@files_meta),
    mapped_urls => scalar(keys %downloaded),
    broken_link_count => scalar(@missing),
    sitemap_pages => scalar(keys %sitemap_pages),
    fetch_failure_count => scalar(@fetch_failures),
  };

  write_file("$REPORT_DIR/mirror-summary.json", JSON::PP->new->pretty->encode($summary));

  my @map = map { "$_\t$downloaded{$_}" } sort keys %downloaded;
  write_file("$REPORT_DIR/url-map.tsv", join("\n", @map) . (@map ? "\n" : ''));

  my @rows = ('source_file\tlink\texpected_local_file');
  push @rows, map { join("\t", @$_) } @missing;
  write_file("$REPORT_DIR/broken-links.tsv", join("\n", @rows) . "\n");
  write_file("$REPORT_DIR/fetch-failures.json", JSON::PP->new->pretty->encode(\@fetch_failures));
  write_file("$REPORT_DIR/sitemap-pages.txt", join("\n", sort keys %sitemap_pages) . "\n");
}

log_msg('Step 1/5: Loading sitemap URLs');
load_sitemaps();
log_msg('Step 2/5: Crawling pages');
crawl_pages();
log_msg('Step 3/5: Crawling assets (including external files where linked)');
crawl_assets();
log_msg('Step 4/5: Rewriting links to root-relative');
rewrite_downloaded();
log_msg('Step 5/5: Building reports');
write_reports();

my $summary_text = slurp("$REPORT_DIR/mirror-summary.json") // '{}';
print $summary_text;
