=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute 
Copyright [2016-2017] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package EnsEMBL::REST::Controller::Info;

use Moose;
use namespace::autoclean;
use Bio::EnsEMBL::ApiVersion;
use Try::Tiny;
use EnsEMBL::REST::EnsemblModel::Biotype;
use EnsEMBL::REST::EnsemblModel::ExternalDB;
require EnsEMBL::REST;
EnsEMBL::REST->turn_on_config_serialisers(__PACKAGE__);

BEGIN {extends 'Catalyst::Controller::REST'; }

__PACKAGE__->config(
  map => {
    'text/plain' => ['YAML'],
  }
);

my %allowed_values = (
  feature => { map { $_, 1} qw(dna_align_feature protein_align_feature unmapped_object xref seq_region_synonym)},
);

sub ping : Local : ActionClass('REST') :Args(0) { }

sub ping_GET {
  my ($self, $c) = @_;
  my ($dba) = @{$c->model('Registry')->get_all_DBAdaptors()};
  my $ping = 0;
  if($dba) {
    try {
      $dba->dbc()->work_with_db_handle(sub {
        my ($dbh) = @_;
        $ping = ($dbh->ping()) ? 1 : 0;
        return;
      });
    }
    catch {
      $c->log()->fatal('Cannot ping the database server due to error');
      $c->log()->fatal($_);
    };
  }
  $self->status_ok($c, entity => { ping => $ping}) if $ping;
  $self->status_gone($c, message => 'Database is unavailable') unless $ping;
  return;
}

sub rest : Local : ActionClass('REST') :Args(0) { }

sub rest_GET :Args(0) {
  my ($self, $c) = @_;
  $self->status_ok($c, entity => { release => $EnsEMBL::REST::VERSION});
  return;
}

sub software : Local : ActionClass('REST') :Args(0) { }

sub software_GET :Args(0) {
  my ($self, $c) = @_;
  my $release = Bio::EnsEMBL::ApiVersion::software_version();
  $self->status_ok($c, entity => { release => $release});
  return;
}

sub data : Local : ActionClass('REST') :Args(0) { }

sub data_GET :Args(0) {
  my ($self, $c) = @_;
  my $releases = $c->model('Registry')->get_unique_schema_versions();
  $self->status_ok($c, entity => { releases => $releases});
  return;
}

sub species : Local : ActionClass('REST') :Args(0) { }

sub species_GET :Local :Args(0) {
  my ($self, $c) = @_;
  my $division = $c->request->param('division');
  my $strain_collection = $c->request->param('strain_collection');
  my $hide_strain_info = $c->request->param('hide_strain_info');
  $hide_strain_info = $hide_strain_info || 0;
  $self->status_ok($c, entity => { species => $c->model('Registry')->get_species($division, $strain_collection, $hide_strain_info)});
  return;
}

sub comparas : Local : ActionClass('REST') :Args(0) { }

sub comparas_GET :Local :Args(0) {
  my ($self, $c) = @_;
  $self->status_ok($c, entity => { comparas => $c->model('Registry')->get_comparas()});
  return;
}

sub analysis :Local :ActionClass('REST') :Args(1) { }

sub analysis_GET :Local :Args(1) { 
  my ($self, $c, $species) = @_;
  my %names;
  my @adaptors = @{$c->model('Registry')->get_all_adaptors_by_type($species, 'analysis')};
  foreach my $adaptor (@adaptors) {
    my $group = $adaptor->db->group;
    foreach my $analysis (@{$adaptor->fetch_all}) {
      push(@{$names{$analysis->logic_name()}}, $group);
    }
  }
  $self->status_ok($c, entity => \%names);
  return;
}

sub external_dbs :Local :ActionClass('REST') :Args(1) { }

sub external_dbs_GET :Local :Args(1) { 
  my ($self, $c, $species) = @_;
  my $dba = $c->model('Registry')->get_DBAdaptor($species, 'core', 1);
  $c->go('ReturnError', 'custom', ["Could not fetch adaptor for species $species"]) unless $dba;
  my $filter = undef || $c->request->param('filter');
  my $feature = undef || $c->request->param('feature');
  if (defined $feature) {
    $c->go('ReturnError', 'custom', ["No external db entries for feature '$feature'"]) unless $allowed_values{feature}{$feature};
  }
  my $dbs = EnsEMBL::REST::EnsemblModel::ExternalDB->get_ExternalDBs($dba, $filter, $feature);
  my @decoded = map { $_->summary_as_hash() } @{$dbs};
  $self->status_ok($c, entity => \@decoded);
  return
}

sub biotypes :Local :ActionClass('REST') :Args(1) { }

sub biotypes_GET :Local :Args(1) { 
  my ($self, $c, $species) = @_;
  my $dba = $c->model('Registry')->get_DBAdaptor($species, 'core', 1);
  $c->go('ReturnError', 'custom', ["Could not fetch adaptor for species $species"]) unless $dba;
  my $obj_biotypes = EnsEMBL::REST::EnsemblModel::Biotype->get_Biotypes($c, $species);
  my @biotypes = map { $_->summary_as_hash() } @{$obj_biotypes};
  $self->status_ok($c, entity => \@biotypes);
  return;
}

sub genomic_methods_GET { }

sub genomic_methods : Chained('/') PathPart('info/compara/methods') Args(0) ActionClass('REST') {
  my ($self, $c) = @_;

  my $class = $c->request->param('class');
  my %types;

  try {
    my $methods = $c->model('Lookup')->find_compara_methods($class);
    push(@{$types{$_->class()}}, $_->type()) for @{$methods};
  } catch {
    $c->go( 'ReturnError', 'from_ensembl', [$_] );
  };

  $self->status_ok($c, entity => \%types);

}

sub species_sets_GET { }

sub species_sets : Chained('/') PathPart("info/compara/species_sets") Args(1) ActionClass('REST') {
  my ($self, $c, $method) = @_;

  my $species_sets;
  try {
    $species_sets = $c->model('Lookup')->find_compara_species_sets($method);
  } catch {
    $c->go( 'ReturnError', 'from_ensembl', [$_] );
  };

  $self->status_ok($c, entity => $species_sets);

}

sub variation :Local :ActionClass('REST') :Args(1) { }

sub variation_GET :Local :Args(1) {
  my ($self, $c, $species) = @_;

  $c->stash(species => $species) if defined $species;

  my $sources ;
  try {
    $sources = $c->model('Variation')->fetch_variation_source_infos($c->request->param('filter'));
  } catch {
    $c->go('ReturnError', 'from_ensembl', [qq{$_}]) if $_ =~ /STACK/;
    $c->go('ReturnError', 'custom', [qq{$_}]);
  };
  $self->status_ok($c, entity => $sources);
  return;
}

sub populations_GET {}

sub populations: Chained('/') PathPart('info/variation/populations') Args(1) ActionClass('REST') {
  my ($self, $c, $species) = @_;
  $c->stash(species => $species) if defined $species;
  my $populations;
  try {
    $populations = $c->model('Variation')->fetch_population_infos($c->request->param('filter'));
  } catch {
    $c->go('ReturnError', 'from_ensembl', [qq{$_}]) if $_ =~ /STACK/;
    $c->go('ReturnError', 'custom', [qq{$_}]);
  };
  $self->status_ok($c, entity => $populations);
  return;
}

sub consequence_types: Path('variation/consequence_types') Args(0) ActionClass('REST') { }

sub consequence_types_GET {
  my ($self, $c) = @_;
  my $consequence_types;
  try {
    $consequence_types = $c->model('Variation')->fetch_consequence_types();
  } catch {
    $c->go('ReturnError', 'from_ensembl', [qq{$_}]) if $_ =~ /STACK/;
    $c->go('ReturnError', 'custom', [qq{$_}]);
  };
  $self->status_ok($c, entity => $consequence_types);
  return;
}

__PACKAGE__->meta->make_immutable;

1;
