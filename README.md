
# Gouania pigra annotation workflow code bundle for hscon VSC

This folder is a cleaned, shareable code bundle for the *Gouania pigra* annotation workflow. It focuses on the scripts and example configuration files that were actually used to produce the final annotation release.

## Included files

- `setup.sh`  
  Cluster setup script for the ERGA Annotato pipeline with local fixes for Funannotate and BRAKER.

- `prepare_annotato_inputs.sh`  
  Builds `params.json`, RNA-seq CSV, and run metadata from a YAML config.

- `config.annotato.example.yaml`  
  Example config for the original Annotato / Funannotate-based run.

- `config.braker.example.yaml`  
  Example config for the BRAKER rerun that reused the softmasked genome and included protein evidence.

- `README.md` / `README.txt`  
  Workflow description and reproducibility notes.

## Workflow overview

### 1. Original Annotato run
The project started with the ERGA Annotato Nextflow pipeline using the Funannotate branch. This step handled:
- RNA read QC and trimming
- STAR mapping
- Repeat masking
- Funannotate-based gene prediction

Core commands:

```bash
bash setup.sh /path/to/annotation /path/to/config.yaml
bash prepare_annotato_inputs.sh config.yaml annotato_inputs

nextflow run software/pipelines/erga-pipelines/annotation/nextflow/main.nf \
  -params-file annotato_inputs/params.json \
  -profile local,singularity \
  -c cluster_override.config
```

### 2. BRAKER rerun
The original annotation underperformed relative to assembly completeness, so a second run was built around BRAKER3. The rerun:
- reused the already generated softmasked genome
- skipped remasking
- added protein evidence
- kept the mapped pigra RNA-seq BAM as evidence

Main config changes:
- `run_braker: true`
- `skip_all_masking: true`
- `skip_functional_annotation: true`
- `skip_rename: true`
- `genome:` set to the softmasked genome
- `protein:` set to a merged protein evidence FASTA

### 3. BRAKER and Funannotate fixes
The setup script was extended to patch several pipeline issues:
- remove invalid `/env` and `/opt/databases` binds in BRAKER
- force `augustus_species` to come from config
- disable problematic Funannotate internal DB setup
- bind the shared Funannotate DB once, at the cluster override level
- pre-pull all containers to avoid runtime hangs

### 4. Recover BRAKER outputs manually
BRAKER itself completed, but Annotato failed when publishing a fragile intermediate directory (`GeneMark-ETP`). The real annotation outputs were recovered directly from the Nextflow work directory.

Recovered outputs:
- `braker.gff3`
- `braker.gtf`
- `braker.aa`
- `braker.codingseq`

### 5. GeMoMa reference-guided prediction
A reference-guided annotation was run with GeMoMa using *Gouania willdenowi* as the reference species.

Inputs:
- target genome: pigra softmasked genome
- target RNA evidence: pigra mapped BAM
- reference genome: *G. willdenowi*
- reference GFF: *G. willdenowi*

Reference-only command:

```bash
java -Xmx120G -jar GeMoMa-1.9.jar CLI GeMoMaPipeline \
  threads=24 \
  outdir=run1 \
  t=target/pigra.softmasked.fa \
  s=own \
  i=Gwill \
  a=ref/Gouania_willdenowi.gff3 \
  g=ref/Gouania_willdenowi.fa \
  r=MAPPED \
  ERE.m=target/pigra.all.sorted.bam \
  ERE.s=FR_UNSTRANDED
```

### 6. GeMoMa + BRAKER consensus
BRAKER was then added as external evidence in a second GeMoMa pipeline run to produce the final structural consensus.

```bash
java -Xmx120G -jar GeMoMa-1.9.jar CLI GeMoMaPipeline \
  threads=24 \
  outdir=run2_consensus \
  GeMoMa.Score=ReAlign \
  AnnotationFinalizer.r=NO \
  o=true \
  t=target/pigra.softmasked.fa \
  s=own \
  i=Gwill \
  a=ref/Gouania_willdenowi.gff3 \
  g=ref/Gouania_willdenowi.fa \
  r=MAPPED \
  ERE.m=target/pigra.all.sorted.bam \
  ERE.s=FR_UNSTRANDED \
  ID=BRAKER \
  e=braker/braker.gff3 \
  weight=7 \
  ae=true
```

The run finished the real work but threw a late `NullPointerException`. The final GFF was recovered from `GeMoMa_temp/.../final_annotation.gff`.

### 7. Sequence extraction
Proteins and CDSs were regenerated from the final consensus GFF using `gffread`:

```bash
gffread final_annotation.gff \
  -g pigra.softmasked.fa \
  -y predicted_proteins.fasta \
  -x predicted_cds.fasta
```

A representative longest-isoform protein FASTA was then generated for BUSCO and downstream orthology-style analyses.

### 8. Functional annotation with eggNOG
Functional annotation was run on the longest-isoform protein set using eggNOG-mapper in a separate environment. The main outputs used downstream were:
- annotation table
- hits table
- seed ortholog assignments
- decorated GFF

### 9. Restore original reference sequence names
The annotation workflow was built on a softmasked genome with `scaffold_*` names. In the final release, sequence names were restored to the official names in `Gouania_pigra_fGouPig1.primary.fasta`.

This was done by:
- matching the official primary FASTA and the softmasked FASTA by exact uppercase sequence identity
- building a map from `scaffold_*` to official names
- renaming seqnames in both structural and eggNOG-decorated GFF files
- regenerating proteins and CDS from the renamed final structural GFF

Representative renaming command:

```bash
awk 'BEGIN{FS=OFS="\t"}
NR==FNR {map[$1]=$2; next}
{
    if ($0 ~ /^#/) {print; next}
    if ($1 in map) $1=map[$1]
    print
}' scaffold_to_primary_map.tsv final_annotation.gff > Gouania_pigra_fGouPig1.primary.annotation.gff3
```

## Key BUSCO progression

- Original Funannotate-based annotation: underperformed relative to the assembly
- BRAKER longest isoform: **C 86.5%**
- GeMoMa reference-only: **C 93.8%**
- GeMoMa + BRAKER consensus, all proteins: **C 95.0%**
- GeMoMa + BRAKER consensus, longest isoform: **C 94.8%**

## Final deliverables produced in the project

Structural:
- final consensus GFF
- proteins FASTA
- CDS FASTA
- longest-isoform protein FASTA

Final renamed release:
- `Gouania_pigra_fGouPig1.primary.annotation.gff3`
- `Gouania_pigra_fGouPig1.primary.proteins.fasta`
- `Gouania_pigra_fGouPig1.primary.cds.fasta`
- `Gouania_pigra_fGouPig1.primary.eggnog.annotations.tsv`
- `Gouania_pigra_fGouPig1.primary.eggnog.decorated.gff3`

## Notes for sharing

Before publishing this bundle externally, review:
- absolute cluster paths
- user-specific scratch locations
- any internal module names
- environment-specific storage settings

The included scripts are the working versions used in the project, but they still contain local cluster paths in the example configs.
