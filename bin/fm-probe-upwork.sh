#!/usr/bin/env bash
# fm-probe-upwork.sh - daily brief source: the captain's Upwork proposal
# pipeline, read from the proposal log only.
#
# Reads data/career/upwork.md, the log the upwork second mate keeps, and never
# opens Upwork, sends, submits, or edits anything. An entry is a top-level
# list line `- YYYY-MM-DD <STATUS> ...` whose status is the run of capital
# words right after the date; a later indented `- YYYY-MM-DD <STATUS> ...`
# line inside the same entry moves it to that status. The first upwork.com job
# link or `~0<digits>` job id names the job; the text after the status and its
# colon, up to the link, is the title. Statuses:
#   DRAFTED, LETTER (ONLY)                  You owe: drafted, not sent
#   SENT...                                 Waiting on others: client reply
#                                           awaited; after
#                                           FM_UPWORK_FOLLOWUP_DAYS (default 7)
#                                           days it says a follow-up is due
#   REPLIED, INTERVIEW, OFFER, MESSAGE      Needs you: the client answered
#   HIRED, CONTRACT, DECLINED, CLOSED, WITHDRAWN, DROPPED, LOST, REJECTED,
#   SKIPPED, ARCHIVED                       closed, no row
# Lines with any other status, or none, are not pipeline entries. Run it
# through `fm-daily-brief.sh source upwork`. FM_UPWORK_LOG overrides the log
# path and FM_BRIEF_NOW=<epoch> the clock. Exit 1 when the log is missing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LOG="${FM_UPWORK_LOG:-${FM_DATA_OVERRIDE:-$FM_HOME/data}/career/upwork.md}"

[ -f "$LOG" ] || { echo "fm-probe-upwork: no proposal log at $LOG" >&2; exit 1; }
case "${FM_BRIEF_NOW:-}" in ''|*[!0-9]*) now=$(date +%s) ;; *) now=$FM_BRIEF_NOW ;; esac

perl -CSD -MJSON::PP -MPOSIX=strftime -e '
  my ($now, $days) = @ARGV;
  my $due = strftime("%Y-%m-%d", localtime($now - 86400 * $days));
  my $json = JSON::PP->new->canonical;
  my (@entries, $cur, %rows, @order);
  while (my $line = <STDIN>) {
    chomp $line;
    if ($line =~ /^- (\d{4}-\d{2}-\d{2}) ([A-Z][A-Z-]*(?: [A-Z][A-Z-]*)*)\b(.*)$/) {
      $cur = { date => $1, status => $2, text => $3 };
      push @entries, $cur;
    } elsif ($line =~ /^\S/) {
      undef $cur;
    } elsif ($cur) {
      if ($line =~ /^\s+[-*] (\d{4}-\d{2}-\d{2}) ([A-Z][A-Z-]*(?: [A-Z][A-Z-]*)*)\b/ && $1 ge $cur->{date}) {
        @$cur{qw(date status)} = ($1, $2);
      }
      $cur->{text} .= " " . $line;
    }
  }
  for my $e (@entries) {
    my ($s, $t) = ($e->{status}, $e->{text});
    my $job = $t =~ m{(?:upwork\.com/jobs/)?(~0\d+)} ? $1 : next;
    my $kind = $s =~ /^(DRAFTED|LETTER)/ ? "drafted"
      : $s =~ /^SENT/ ? "sent"
      : $s =~ /^(REPLIED|INTERVIEW|OFFER|MESSAGE)/ ? "replied"
      : $s =~ /^(HIRED|CONTRACT|DECLINED|CLOSED|WITHDRAWN|DROPPED|LOST|REJECTED|SKIPPED|ARCHIVED)/ ? "closed" : next;
    if ($kind eq "closed") { delete $rows{"upwork:$job"}; next }
    (my $title = $t) =~ s/^[^:]*:\s*//;
    $title =~ s/\s*(?:-\s*)?(?:https?:\/\/\S+|~0\d+).*$//;
    $title =~ s/\s+/ /g; $title =~ s/^\s+|\s+$//g; $title =~ s/\s*-$//;
    $title = "job $job" if $title eq "";
    $title = substr($title, 0, 90);
    my %row = (id => "upwork:$job", url => "https://www.upwork.com/jobs/$job");
    if ($kind eq "drafted") {
      @row{qw(section title)} = ("owe", "Upwork proposal drafted $e->{date}, not sent: $title");
    } elsif ($kind eq "replied") {
      @row{qw(section title)} = ("needs", "Upwork client answered ($e->{date}): $title");
    } elsif ($e->{date} le $due) {
      @row{qw(section title)} = ("waiting", "Upwork client, no reply since $e->{date} - follow-up due: $title");
    } else {
      @row{qw(section title)} = ("waiting", "Upwork client reply awaited since $e->{date}: $title");
    }
    push @order, $row{id} unless grep { $_ eq $row{id} } @order;
    $rows{$row{id}} = $json->encode(\%row);
  }
  print "$rows{$_}\n" for grep { exists $rows{$_} } @order;
' "$now" "${FM_UPWORK_FOLLOWUP_DAYS:-7}" < "$LOG"
