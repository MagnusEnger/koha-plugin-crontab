use utf8;

package Koha::Plugin::Com::PTFSEurope::Crontab;

use Modern::Perl;
use base qw(Koha::Plugins::Base);

use POSIX qw(strftime);
use Module::Metadata;
use Config::Crontab;
use YAML::XS;

$YAML::XS::Boolean = "JSON::PP";

#BEGIN {
#    my $path = Module::Metadata->find_module_by_name(__PACKAGE__);
#    $path =~ s!\.pm$!/lib!;
#    unshift @INC, $path;
#
#    use Crontab::API;
#}

our $VERSION  = "{VERSION}";
our $metadata = {
    name            => 'Crontab',
    author          => 'Martin Renvoize',
    description     => 'Add instance crontab management to Koha',
    date_authored   => '2023-04-25',
    date_updated    => "1970-01-01",
    minimum_version => '22.1100000',
    maximum_version => undef,
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    my $self = $class->SUPER::new($args);

    return $self;
}

sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'crontab.tt' } );

    my $ct = Config::Crontab->new();
    $ct->mode('block');
    $ct->read or do {
        $template->param( error => $ct->error );
        $self->output_html( $template->output() );
        return;
    };

    my $blocks = [];
    my @environment;
    for my $block ( $ct->blocks ) {

        # Get block parts
        my @comments = $block->select( -type => 'comment' );
        my @env      = $block->select( -type => 'env' );
        my @events   = $block->select( -type => 'event' );

        # Get block id
        my $id_line = shift @comments;

        # Skip first block (plugin header)
        next if ( $id_line->data =~ 'Koha Crontab manager' );

        # Set block id
        my $id;
        if ( $id_line->data =~ /# BLOCKID: (\d+)/ ) {
            $id = $1;
        }
        else {
            $template->param(
                error => "Found block with missing ID: " . $id_line->data );
            $self->output_html( $template->output() );
            return;
        }

        # Global environment block
        unless (@events) {
            push @environment, @env;
            next;
        }

        push @{$blocks},
          {
            id          => $id,
            comments    => \@comments,
            environment => \@env,
            events      => \@events
          };
    }
    $template->param(
        environment => \@environment,
        blocks      => $blocks
    );
    $self->output_html( $template->output() );
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.yaml');
    my $spec     = Load $spec_str;

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'crontab';
}

sub install() {
    my ( $self, $args ) = @_;

    my $existing = 1;

    my $ct = Config::Crontab->new();
    $ct->mode('block');
    $ct->read or do {
        $existing = 0;
        warn "No crontab found, installing default";
    };

    # Take a backup
    if ($existing) {
        my $path       = $self->mbf_dir . '/backups/';
        my $now_string = strftime "%F_%H-%M-%S", localtime;
        my $filename   = $path . 'install_' . $now_string;
        $ct->write("$filename");

        # Read existing crontab, update it to identify blocks
        # we can manage
        # BLOCKID:
        my $block_id = 1;
        for my $block ( $ct->blocks ) {
            for my $comment (
                $block->select(
                    -type    => 'comment',
                    -data_re => 'Koha Crontab manager'
                )
              )
            {
                return 1;    # Already installed
            }
            $block->first(
                Config::Crontab::Comment->new(
                    -data => "# BLOCKID: " . $block_id++
                )
            );
        }
    }

    # Set first block to state we're maintained by the plugin
    my $block = Config::Crontab::Block->new();
    $block->first(
        Config::Crontab::Comment->new(
            -data =>
"# This crontab file is managed by the Koha Crontab manager plugin"
        )
    );
    $ct->first($block);

    # Add a hash so we can tell if the managed content has
    # been modified externally and warn the user during updates

    ## write out crontab file
    warn "Writing crontab: " . $ct->dump;
    $ct->write;

    return 1;
}

1;
