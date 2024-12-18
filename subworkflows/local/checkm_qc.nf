/*
 * CheckM: Quantitative measures for the assessment of genome assembly
 */

include { CHECKM_QA                             } from '../../modules/nf-core/checkm/qa/main'
include { CHECKM_LINEAGEWF                      } from '../../modules/nf-core/checkm/lineagewf/main'
include { COMBINE_TSV as COMBINE_CHECKM_QA_TSV  } from '../../modules/local/combine_tsv'
include { COMBINE_TSV as COMBINE_CHECKM_LIN_TSV } from '../../modules/local/combine_tsv'
include { GALAH                                 } from '../../modules/local/galah'

workflow CHECKM_QC {
    take:
    bins       // channel: [ val(meta), path(bin) ]
    checkm_db

    main:
    ch_versions = Channel.empty()

    ch_input_checkmdb = checkm_db ? checkm_db : []
    ch_bins_for_checkmlineagewf = bins
                                    .multiMap {
                                        meta, fa ->
                                            reads: [ meta, fa ]
                                            ext: fa.extension.unique().join("") // we set this in the pipeline to always `.fa` so this should be fine
                                    }

    CHECKM_LINEAGEWF ( ch_bins_for_checkmlineagewf.reads, ch_bins_for_checkmlineagewf.ext, checkm_db )
    ch_versions = ch_versions.mix(CHECKM_LINEAGEWF.out.versions.first())

    ch_checkmqa_input = CHECKM_LINEAGEWF.out.checkm_output
        .join(CHECKM_LINEAGEWF.out.marker_file)
        .map{
            meta, dir, marker ->
            [ meta, dir, marker, []]
        }

    CHECKM_QA ( ch_checkmqa_input, [] )
    ch_versions = ch_versions.mix(CHECKM_QA.out.versions.first())

    COMBINE_CHECKM_LIN_TSV ( CHECKM_LINEAGEWF.out.checkm_tsv.map{it[1]}.collect() )
    COMBINE_CHECKM_QA_TSV ( CHECKM_QA.out.output.map{it[1]}.collect() )

    ch_input_galah = ch_bins_for_checkmlineagewf.reads
                            .map{it[1]}
                            .collect()
                            .map { it -> tuple("all", it, "checkm") }
                            .combine(COMBINE_CHECKM_LIN_TSV.out.combined)
                            .map { it -> tuple(it[0], it[1], it[3], it[2])}
    GALAH ( ch_input_galah )

    emit:
    summary    = COMBINE_CHECKM_QA_TSV.out.combined
    checkm_tsv = CHECKM_QA.out.output
    versions   = ch_versions
}
