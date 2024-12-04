/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { MULTIQC                } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap       } from 'plugin/nf-validation'
include { paramsSummaryMultiqc   } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_saltprofiler'

//
// SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
//
include { METAPHLAN                       } from '../subworkflows/local/metaphlan'
include { BINNING_PREPARATION             } from '../subworkflows/local/binning_preparation'
include { BINNING                         } from '../subworkflows/local/binning'
include { BUSCO_QC                        } from '../subworkflows/local/busco_qc'
include { CHECKM_QC                       } from '../subworkflows/local/checkm_qc'
include { DEPTHS                          } from '../subworkflows/local/depths'
include { SALTGENES                       } from '../subworkflows/local/saltgenes'

//
// MODULE: Installed directly from nf-core/modules
//
include { ARIA2 as ARIA2_UNTAR                                  } from '../modules/nf-core/aria2/main'
include { FASTQC as FASTQC_RAW                                  } from '../modules/nf-core/fastqc/main'
include { FASTQC as FASTQC_TRIMMED                              } from '../modules/nf-core/fastqc/main'
include { SEQTK_MERGEPE                                         } from '../modules/nf-core/seqtk/mergepe/main'
include { BBMAP_BBNORM                                          } from '../modules/nf-core/bbmap/bbnorm/main'
include { FASTP                                                 } from '../modules/nf-core/fastp/main'
include { ADAPTERREMOVAL as ADAPTERREMOVAL_PE                   } from '../modules/nf-core/adapterremoval/main'
include { ADAPTERREMOVAL as ADAPTERREMOVAL_SE                   } from '../modules/nf-core/adapterremoval/main'
include { CAT_FASTQ                                             } from '../modules/nf-core/cat/fastq/main'
include { GUNZIP as GUNZIP_ASSEMBLIES                           } from '../modules/nf-core/gunzip'
include { PRODIGAL                                              } from '../modules/nf-core/prodigal/main'
include { PROKKA                                                } from '../modules/nf-core/prokka/main'

//
// MODULE: Local to the pipeline
//
include { BOWTIE2_REMOVAL_BUILD as BOWTIE2_HOST_REMOVAL_BUILD } from '../modules/local/bowtie2_removal_build'
include { BOWTIE2_REMOVAL_ALIGN as BOWTIE2_HOST_REMOVAL_ALIGN } from '../modules/local/bowtie2_removal_align'
include { BOWTIE2_REMOVAL_BUILD as BOWTIE2_PHIX_REMOVAL_BUILD } from '../modules/local/bowtie2_removal_build'
include { BOWTIE2_REMOVAL_ALIGN as BOWTIE2_PHIX_REMOVAL_ALIGN } from '../modules/local/bowtie2_removal_align'
include { POOL_SINGLE_READS as POOL_SHORT_SINGLE_READS        } from '../modules/local/pool_single_reads'
include { POOL_PAIRED_READS                                   } from '../modules/local/pool_paired_reads'
include { MEGAHIT                                             } from '../modules/local/megahit'
include { SPADES                                              } from '../modules/local/spades'
include { QUAST                                               } from '../modules/local/quast'
include { QUAST_BINS                                          } from '../modules/local/quast_bins'
include { QUAST_BINS_SUMMARY                                  } from '../modules/local/quast_bins_summary'
include { CAT_DB                                              } from '../modules/local/cat_db'
include { CAT_DB_GENERATE                                     } from '../modules/local/cat_db_generate'
include { CAT                                                 } from '../modules/local/cat'
include { CAT_SUMMARY                                         } from "../modules/local/cat_summary"
include { BIN_SUMMARY                                         } from '../modules/local/bin_summary'
include { COMBINE_TSV as COMBINE_SUMMARY_TSV                  } from '../modules/local/combine_tsv'
include { KRAKEN2                                             } from "../modules/local/kraken2"
include { COMBINE_TSV as COMBINE_SUMMARY_TSV                  } from '../modules/local/combine_tsv'

////////////////////////////////////////////////////
/* --  Create channel for reference databases  -- */
////////////////////////////////////////////////////

if ( params.host_genome ) {
    host_fasta = params.genomes[params.host_genome].fasta ?: false
    ch_host_fasta = Channel
        .value(file( "${host_fasta}" ))
    host_bowtie2index = params.genomes[params.host_genome].bowtie2 ?: false
    ch_host_bowtie2index = Channel
        .value(file( "${host_bowtie2index}/*" ))
} else if ( params.host_fasta ) {
    ch_host_fasta = Channel
        .value(file( "${params.host_fasta}" ))
} else {
    ch_host_fasta = Channel.empty()
}

if (params.busco_db) {
    ch_busco_db = file(params.busco_db, checkIfExists: true)
} else {
    ch_busco_db = []
}

if(params.checkm_db) {
    ch_checkm_db = file(params.checkm_db, checkIfExists: true)
}

if(params.cat_db){
    ch_cat_db_file = Channel
        .value(file( "${params.cat_db}" ))
} else {
    ch_cat_db_file = Channel.empty()
}

if(!params.keep_phix) {
    ch_phix_db_file = Channel
        .value(file( "${params.phix_reference}" ))
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def busco_failed_bins = [:]

workflow SALTPROFILER {

    take:
    ch_raw_short_reads // channel: samplesheet read in from --input
    ch_input_assemblies
    ch_input_genes

    main:

    ch_versions = Channel.empty()
    ch_multiqc_files = Channel.empty()

    // Get checkM database if not supplied

    if ( !params.skip_binqc && params.binqc_tool == 'checkm' && !params.checkm_db ) {
        ARIA2_UNTAR (params.checkm_download_url)
        ch_checkm_db = ARIA2_UNTAR.out.downloaded_file
    }

    /*
    ================================================================================
                                    Preprocessing and QC for short reads
    ================================================================================
    */

    // FASTQC_RAW ( ch_raw_short_reads )
    // ch_versions = ch_versions.mix(FASTQC_RAW.out.versions.first())

    ch_bowtie2_removal_host_multiqc = Channel.empty()
    if ( !params.assembly_input ) {
        if ( !params.skip_clipping ) {
            if ( params.clip_tool == 'fastp' ) {
                ch_clipmerge_out = FASTP (
                    ch_raw_short_reads,
                    [],
                    params.fastp_save_trimmed_fail,
                    []
                )
                ch_short_reads_prepped = FASTP.out.reads
                ch_versions = ch_versions.mix(FASTP.out.versions.first())

            } else if ( params.clip_tool == 'adapterremoval' ) {

                // due to strange output file scheme in AR2, have to manually separate
                // SE/PE to allow correct pulling of reads after.
                ch_adapterremoval_in = ch_raw_short_reads
                    .branch {
                            single: it[0]['single_end']
                            paired: !it[0]['single_end']
                        }

                ADAPTERREMOVAL_PE ( ch_adapterremoval_in.paired, [] )
                ADAPTERREMOVAL_SE ( ch_adapterremoval_in.single, [] )

            ch_short_reads_prepped = Channel.empty()
            ch_short_reads_prepped = ch_short_reads_prepped.mix(ADAPTERREMOVAL_SE.out.singles_truncated, ADAPTERREMOVAL_PE.out.paired_truncated)

                ch_versions = ch_versions.mix(ADAPTERREMOVAL_PE.out.versions.first(), ADAPTERREMOVAL_SE.out.versions.first())
            }
        } else {
            ch_short_reads_prepped = ch_raw_short_reads
        }

        if (params.host_fasta){
            if ( params.host_fasta_bowtie2index ) {
                ch_host_bowtie2index = file(params.host_fasta_bowtie2index, checkIfExists: true)
            } else {
                BOWTIE2_HOST_REMOVAL_BUILD (
                    ch_host_fasta
                )
                ch_host_bowtie2index = BOWTIE2_HOST_REMOVAL_BUILD.out.index
            }

        }

        ch_bowtie2_removal_host_multiqc = Channel.empty()
        if (params.host_fasta || params.host_genome){
            BOWTIE2_HOST_REMOVAL_ALIGN (
                ch_short_reads_prepped,
                ch_host_bowtie2index
            )
            ch_short_reads_hostremoved = BOWTIE2_HOST_REMOVAL_ALIGN.out.reads
            ch_bowtie2_removal_host_multiqc = BOWTIE2_HOST_REMOVAL_ALIGN.out.log
            ch_versions = ch_versions.mix(BOWTIE2_HOST_REMOVAL_ALIGN.out.versions.first())
        } else {
            ch_short_reads_hostremoved = ch_short_reads_prepped
        }

        if(!params.keep_phix) {
            BOWTIE2_PHIX_REMOVAL_BUILD (
                ch_phix_db_file
            )
            BOWTIE2_PHIX_REMOVAL_ALIGN (
                ch_short_reads_hostremoved,
                BOWTIE2_PHIX_REMOVAL_BUILD.out.index
            )
            ch_short_reads_phixremoved = BOWTIE2_PHIX_REMOVAL_ALIGN.out.reads
            ch_versions = ch_versions.mix(BOWTIE2_PHIX_REMOVAL_ALIGN.out.versions.first())
        } else {
            ch_short_reads_phixremoved = ch_short_reads_hostremoved
        }

        // if (!(params.keep_phix && params.skip_clipping && !(params.host_genome || params.host_fasta))) {
        //     FASTQC_TRIMMED (
        //         ch_short_reads_phixremoved
        //     )
        //     ch_versions = ch_versions.mix(FASTQC_TRIMMED.out.versions)
        // }

        // Run/Lane merging

        ch_short_reads_forcat = ch_short_reads_phixremoved
            .map {
                meta, reads ->
                    def meta_new = meta - meta.subMap('run')
                [ meta_new, reads ]
            }
            .groupTuple()
            .branch {
                meta, reads ->
                    cat:      reads.size() >= 2 // SE: [[meta], [S1_R1, S2_R1]]; PE: [[meta], [[S1_R1, S1_R2], [S2_R1, S2_R2]]]
                    skip_cat: true // Can skip merging if only single lanes
            }

        CAT_FASTQ ( ch_short_reads_forcat.cat.map { meta, reads -> [ meta, reads.flatten() ]} )

        // Ensure we don't have nests of nests so that structure is in form expected for assembly
        ch_short_reads_catskipped = ch_short_reads_forcat.skip_cat
                                        .map { meta, reads ->
                                            def new_reads = meta.single_end ? reads[0] : reads.flatten()
                                        [ meta, new_reads ]
                                    }

        // Combine single run and multi-run-merged data
        ch_short_reads = Channel.empty()
        ch_short_reads = CAT_FASTQ.out.reads.mix(ch_short_reads_catskipped)
        ch_versions    = ch_versions.mix(CAT_FASTQ.out.versions.first())

        if ( params.bbnorm ) {
            if ( params.coassemble_group ) {
                // Interleave pairs, to be able to treat them as single ends when calling bbnorm. This prepares
                // for dropping the single_end parameter, but keeps assembly modules as they are, i.e. not
                // accepting a mix of single end and pairs.
                SEQTK_MERGEPE (
                    ch_short_reads.filter { ! it[0].single_end }
                )
                ch_versions = ch_versions.mix(SEQTK_MERGEPE.out.versions.first())
                // Combine the interleaved pairs with any single end libraries. Set the meta.single_end to true (used by the bbnorm module).
                    ch_bbnorm = SEQTK_MERGEPE.out.reads
                        .mix(ch_short_reads.filter { it[0].single_end })
                        .map { [ [ id: sprintf("group%s", it[0].group), group: it[0].group, single_end: true ], it[1] ] }
                        .groupTuple()
            } else {
                ch_bbnorm = ch_short_reads
            }
            BBMAP_BBNORM ( ch_bbnorm )
            ch_versions = ch_versions.mix(BBMAP_BBNORM.out.versions)
            ch_short_reads_assembly = BBMAP_BBNORM.out.fastq
        } else {
            ch_short_reads_assembly = ch_short_reads
        }
    } else {
        ch_short_reads = ch_raw_short_reads
                        .map {
                            meta, reads ->
                                def meta_new = meta - meta.subMap('run')
                            [ meta_new, reads ]
                        }
    }


    /*
    ================================================================================
                                    Taxonomic information
    ================================================================================
    */

    if ( !params.skip_metaphlan ) {
        METAPHLAN (
            ch_short_reads
        )
        ch_versions = ch_versions.mix(METAPHLAN.out.versions.first())
    }
    

    /*
    ================================================================================
                                    Assembly
    ================================================================================
    */

    if ( !params.assembly_input ) {
        // Co-assembly: prepare grouping for MEGAHIT and for pooling for SPAdes
        if (params.coassemble_group) {
            // short reads
            // group and set group as new id
            ch_short_reads_grouped = ch_short_reads_assembly
                .map { meta, reads -> [ meta.group, meta, reads ] }
                .groupTuple(by: 0)
                .map { group, metas, reads ->
                    def assemble_as_single = params.single_end || ( params.bbnorm && params.coassemble_group )
                    def meta         = [:]
                    meta.id          = "group-$group"
                    meta.group       = group
                    meta.single_end  = assemble_as_single
                    if ( assemble_as_single ) [ meta, reads.collect { it }, [] ]
                    else [ meta, reads.collect { it[0] }, reads.collect { it[1] } ]
                }
        } else {
            ch_short_reads_grouped = ch_short_reads_assembly
                .filter { it[0].single_end }
                .map { meta, reads -> [ meta, [ reads ], [] ] }
                .mix (
                    ch_short_reads_assembly
                        .filter { ! it[0].single_end }
                        .map { meta, reads -> [ meta, [ reads[0] ], [ reads[1] ] ] }
                )
        }

        ch_assemblies = Channel.empty()

        if (!params.skip_megahit){
            MEGAHIT ( ch_short_reads_grouped )
            ch_megahit_assemblies = MEGAHIT.out.assembly
                .map { meta, assembly ->
                    def meta_new = meta + [assembler: 'MEGAHIT']
                    [ meta_new, assembly ]
                }
            ch_assemblies = ch_assemblies.mix(ch_megahit_assemblies)
            ch_versions = ch_versions.mix(MEGAHIT.out.versions.first())
        }

        // Co-assembly: pool reads for SPAdes
        if ( ! params.skip_spades ){
            if ( params.coassemble_group ) {
                if ( params.bbnorm ) {
                    ch_short_reads_spades = ch_short_reads_grouped.map { [ it[0], it[1] ] }
                } else {
                    POOL_SHORT_SINGLE_READS (
                        ch_short_reads_grouped
                            .filter { it[0].single_end }
                    )
                    POOL_PAIRED_READS (
                        ch_short_reads_grouped
                            .filter { ! it[0].single_end }
                    )
                    ch_short_reads_spades = POOL_SHORT_SINGLE_READS.out.reads
                        .mix(POOL_PAIRED_READS.out.reads)
                }
            } else {
                ch_short_reads_spades = ch_short_reads_assembly
            }
        } else {
            ch_short_reads_spades = Channel.empty()
        }

        if (!params.single_end && !params.skip_spades){
            SPADES ( ch_short_reads_spades )
            ch_spades_assemblies = SPADES.out.assembly
                .map { meta, assembly ->
                    def meta_new = meta + [assembler: 'SPAdes']
                    [ meta_new, assembly ]
                }
            ch_assemblies = ch_assemblies.mix(ch_spades_assemblies)
            ch_versions = ch_versions.mix(SPADES.out.versions.first())
        }
    } else { // if assemblies were provided as input
        ch_assemblies_split = ch_input_assemblies
            .branch { meta, assembly ->
                gzipped: assembly.getExtension() == "gz"
                ungzip: true
            }

        GUNZIP_ASSEMBLIES(ch_assemblies_split.gzipped)
        ch_versions = ch_versions.mix(GUNZIP_ASSEMBLIES.out.versions)

        ch_assemblies = Channel.empty()
        ch_assemblies = ch_assemblies.mix(ch_assemblies_split.ungzip, GUNZIP_ASSEMBLIES.out.gunzip)
    }

    // QUAST for assemblies
    ch_quast_multiqc = Channel.empty()
    if (!params.skip_quast){
        QUAST ( ch_assemblies )
        ch_versions = ch_versions.mix(QUAST.out.versions.first())
    }

    /*
    ================================================================================
                                    Predict proteins
    ================================================================================
    */

    if (!params.skip_prodigal){
        PRODIGAL (
            ch_assemblies,
            'gff'
        )
        ch_versions = ch_versions.mix(PRODIGAL.out.versions.first())
    }

    /*
    ================================================================================
                                Binning preparation
    ================================================================================
    */

    ch_busco_summary            = Channel.empty()
    ch_checkm_summary           = Channel.empty()

    if ( !params.skip_binning ) {
        BINNING_PREPARATION (
            ch_assemblies,
            ch_short_reads
        )
        ch_versions = ch_versions.mix(BINNING_PREPARATION.out.bowtie2_version.first())
    }

    /*
    ================================================================================
                                    Binning
    ================================================================================
    */

    if (!params.skip_binning){
        BINNING (
            BINNING_PREPARATION.out.grouped_mappings,
            ch_short_reads
        )
        ch_versions = ch_versions.mix(BINNING.out.versions)

        ch_binning_results_bins = BINNING.out.bins
            .map { meta, bins ->
                def meta_new = meta + [domain: 'unclassified']
                [meta_new, bins]
            }
        ch_binning_results_unbins = BINNING.out.unbinned
            .map { meta, bins ->
                def meta_new = meta + [domain: 'unclassified']
                [meta_new, bins]
            }

        ch_input_for_postbinning_bins        = ch_binning_results_bins
        ch_input_for_postbinning_bins_unbins = ch_binning_results_bins.mix(ch_binning_results_unbins)

        DEPTHS ( ch_input_for_postbinning_bins_unbins, BINNING.out.metabat2depths, ch_short_reads )
        ch_input_for_binsummary = DEPTHS.out.depths_summary
        ch_versions = ch_versions.mix(DEPTHS.out.versions)

        /*
        * Bin QC subworkflows: for checking bin completeness with BUSCO or CHECKM
        */

        ch_input_bins_for_qc = ch_input_for_postbinning_bins_unbins.transpose()

        if (!params.skip_binqc && params.binqc_tool == 'busco'){
            /*
            * BUSCO subworkflow: Quantitative measures for the assessment of genome assembly
            */

            BUSCO_QC (
                ch_busco_db,
                ch_input_bins_for_qc
            )
            ch_busco_summary = BUSCO_QC.out.summary
            ch_versions = ch_versions.mix(BUSCO_QC.out.versions.first())
            // process information if BUSCO analysis failed for individual bins due to no matching genes
            BUSCO_QC.out
                .failed_bin
                .splitCsv(sep: '\t')
                .map { bin, error -> if (!bin.contains(".unbinned.")) busco_failed_bins[bin] = error }
        }

        if (!params.skip_binqc && params.binqc_tool == 'checkm'){
            /*
            * CheckM subworkflow: Quantitative measures for the assessment of genome assembly
            */

            ch_input_bins_for_checkm = ch_input_bins_for_qc
                .filter { meta, bins ->
                    meta.domain != "eukarya"
                }

            CHECKM_QC (
                ch_input_bins_for_checkm.groupTuple(),
                ch_checkm_db
            )
            ch_checkm_summary = CHECKM_QC.out.summary

            ch_versions = ch_versions.mix(CHECKM_QC.out.versions)

        }

        ch_quast_bins_summary = Channel.empty()
        if (!params.skip_quast){
            ch_input_for_quast_bins = ch_input_for_postbinning_bins_unbins
                                        .groupTuple()
                                        .map {
                                            meta, bins ->
                                                def new_bins = bins.flatten()
                                                [meta, new_bins]
                                            }

            QUAST_BINS ( ch_input_for_quast_bins )
            ch_versions = ch_versions.mix(QUAST_BINS.out.versions.first())
            ch_quast_bin_summary = QUAST_BINS.out.quast_bin_summaries
                .collectFile(keepHeader: true) {
                    meta, summary ->
                    ["${meta.id}.tsv", summary]
            }
            QUAST_BINS_SUMMARY ( ch_quast_bin_summary.collect() )
            ch_quast_bins_summary = QUAST_BINS_SUMMARY.out.summary
        }

        
        ch_cat_db = Channel.empty()
        if ( !params.skip_taxbins ) {
        /*
        * CAT: taxonomic classification of bins
        */
        if ( params.taxtool == "CAT" ) {
            if (params.cat_db){
                CAT_DB ( ch_cat_db_file )
                ch_cat_db = CAT_DB.out.db
            } else if (params.cat_db_generate){
                CAT_DB_GENERATE ()
                ch_cat_db = CAT_DB_GENERATE.out.db
            }
            CAT (
                ch_input_for_postbinning_bins_unbins,
                ch_cat_db
            )
            // Group all classification results for each sample in a single file
            ch_cat_summary = CAT.out.tax_classification_names
                .collectFile(keepHeader: true) {
                        meta, classification ->
                        ["${meta.id}.txt", classification]
                }
            // Group all classification results for the whole run in a single file
            CAT_SUMMARY(
                ch_cat_summary.collect()
            )
            ch_versions = ch_versions.mix(CAT.out.versions.first())
            ch_versions = ch_versions.mix(CAT_SUMMARY.out.versions)
        }
            // If CAT is not run, then the CAT global summary should be an empty channel
            if ( params.cat_db_generate || params.cat_db ) {
                ch_cat_global_summary = CAT_SUMMARY.out.combined
            } else {
                ch_cat_global_summary = Channel.empty()
            }
        if(params.taxtool == 'kraken'){
            /*
            * KRAKEN: taxonomic classification of bins
            */
            KRAKEN2 (
                ch_input_for_postbinning_bins_unbins,
                ch_kraken_db,
                ch_taxtable
            )
            ch_versions = ch_versions.mix(KRAKEN2.out.versions.first())
            
            // Group all classification results for the whole run in a single file
            COMBINE_SUMMARY_TSV ( KRAKEN2.out.tax.map{it[1]}.collect() )
        }
        }

        /*
         * Prokka: Genome annotation
         */

        if (!params.skip_prokka){
            ch_bins_for_prokka = ch_input_for_postbinning_bins_unbins.transpose()
            .map { meta, bin ->
                def meta_new = meta + [id: bin.getBaseName()]
                [ meta_new, bin ]
            }
            .filter { meta, bin ->
                meta.domain != "eukarya"
            }

            PROKKA (
                ch_bins_for_prokka,
                [],
                []
            )
            ch_versions = ch_versions.mix(PROKKA.out.versions.first())

                    /*
                    * Overview of salt tolerance genes
                    */

                    if ( !params.skip_saltgenes ) {
                        ch_prokka_output = PROKKA.out.gff.combine(PROKKA.out.fna, by: 0)
                        SALTGENES(
                            ch_input_genes,
                            ch_prokka_output,
                            ch_short_reads,
                            CAT.out.tax_classification_names
                        )
                    ch_versions = ch_versions.mix(SALTGENES.out.versions.first())
                    }
            } else {
                ch_cat_global_summary = Channel.empty()
            }

            if ( ( !params.skip_binqc ) || !params.skip_quast || !params.skip_taxbins){
                BIN_SUMMARY (
                    ch_input_for_binsummary,
                    ch_busco_summary.ifEmpty([]),
                    ch_checkm_summary.ifEmpty([]),
                    ch_quast_bins_summary.ifEmpty([]),
                    ch_cat_global_summary.ifEmpty([])
                )
            }
        }
    }
        


    //
    // Collate and save software versions
    //
    softwareVersionsToYAML(ch_versions)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'nf_core_pipeline_software_mqc_versions.yml',
            sort: true,
            newLine: true
        ).set { ch_collated_versions }

    //
    // MODULE: MultiQC
    //
    ch_multiqc_config        = Channel.fromPath(
        "$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config = params.multiqc_config ?
        Channel.fromPath(params.multiqc_config, checkIfExists: true) :
        Channel.empty()
    ch_multiqc_logo          = params.multiqc_logo ?
        Channel.fromPath(params.multiqc_logo, checkIfExists: true) :
        Channel.fromPath("${workflow.projectDir}/docs/images/mag_logo_mascot_light.png", checkIfExists: true)

    summary_params      = paramsSummaryMap(
        workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary = Channel.value(paramsSummaryMultiqc(summary_params))

    ch_multiqc_custom_methods_description = params.multiqc_methods_description ?
        file(params.multiqc_methods_description, checkIfExists: true) :
        file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description                = Channel.value(
        methodsDescriptionText(ch_multiqc_custom_methods_description))

    ch_multiqc_files = ch_multiqc_files.mix(
        ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_methods_description.collectFile(
            name: 'methods_description_mqc.yaml',
            sort: true
        )
    )

    // ch_multiqc_files = ch_multiqc_files.mix(FASTQC_RAW.out.zip.collect{it[1]}.ifEmpty([]))

    if (!params.assembly_input) {

        if ( !params.skip_clipping && params.clip_tool == 'adapterremoval' ) {
            ch_multiqc_files = ch_multiqc_files.mix(ADAPTERREMOVAL_PE.out.settings.collect{it[1]}.ifEmpty([]))
            ch_multiqc_files = ch_multiqc_files.mix(ADAPTERREMOVAL_SE.out.settings.collect{it[1]}.ifEmpty([]))

        } else if ( !params.skip_clipping && params.clip_tool == 'fastp' )  {
            ch_multiqc_files = ch_multiqc_files.mix(FASTP.out.json.collect{it[1]}.ifEmpty([]))
        }

        // if (!(params.keep_phix && params.skip_clipping && !(params.host_genome || params.host_fasta))) {
        //     ch_multiqc_files = ch_multiqc_files.mix(FASTQC_TRIMMED.out.zip.collect{it[1]}.ifEmpty([]))
        // }

        if ( params.host_fasta || params.host_genome ) {
            ch_multiqc_files = ch_multiqc_files.mix(BOWTIE2_HOST_REMOVAL_ALIGN.out.log.collect{it[1]}.ifEmpty([]))
        }

        if(!params.keep_phix) {
            ch_multiqc_files = ch_multiqc_files.mix(BOWTIE2_PHIX_REMOVAL_ALIGN.out.log.collect{it[1]}.ifEmpty([]))
        }

    }

    if (!params.skip_quast){
        ch_multiqc_files = ch_multiqc_files.mix(QUAST.out.report.collect().ifEmpty([]))

        if ( !params.skip_binning ) {
            ch_multiqc_files = ch_multiqc_files.mix(QUAST_BINS.out.dir.collect().ifEmpty([]))
        }
    }

    if (!params.skip_binning && !params.skip_prokka){
        ch_multiqc_files = ch_multiqc_files.mix(PROKKA.out.txt.collect{it[1]}.ifEmpty([]))
    }

    if (!params.skip_binning && !params.skip_binqc && params.binqc_tool == 'busco'){
        ch_multiqc_files = ch_multiqc_files.mix(BUSCO_QC.out.multiqc.collect().ifEmpty([]))
    }


    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )

    emit:
    multiqc_report = MULTIQC.out.report.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/