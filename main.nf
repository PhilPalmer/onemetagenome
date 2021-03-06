#!/usr/bin/env nextflow
/*
========================================================================================
                         PhilPalmer/onemetagenome
========================================================================================
 onemetagenome Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/PhilPalmer/onemetagenome
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    log.info"""
    =========================================
     onemetagenome
    =========================================
    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run PhilPalmer/onemetagenome --reads_folder 'data/reads' --fas data/DB.fasta -profile standard,docker

    Mandatory arguments:
      --reads_folder                Path to input data folder
      --fas                         Fasta file database used to query against
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: standard, conda, docker, singularity, awsbatch, test

    Options:
      --singleEnd                   Specifies that the input is single end reads

    References                      If not specified in the configuration file or you wish to overwrite any of the references.
      --fasta                       Path to Fasta reference

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */
params.reads_folder = "s3://lifebit-featured-datasets/containers/plass"
params.reads_extension = "fastq"
if (params.singleEnd) {
      reads_path="${params.reads_folder}/*.${params.reads_extension}"
  } else {
      reads_path="${params.reads_folder}/*{1,2}.${params.reads_extension}"
}

//params.fas = "s3://lifebit-featured-datasets/containers/mmseqs2/DB.fasta"
//fas = file(params.fas)

params.targetdb_folder = "s3://lifebit-featured-datasets/pipelines/onemetagenome-data/targetDB"
targetdb_folder = params.targetdb_folder

params.uniprot = "s3://lifebit-featured-datasets/pipelines/onemetagenome-data/uniprot_sprot.dat.gz"
uniprot = file(params.uniprot)

params.taxdump = "ftp://ftp.ncbi.nih.gov/pub/taxonomy/taxdump.tar.gz"
taxdump = file(params.taxdump)

params.outdir = "results"
outdir = "${params.outdir}"

params.benchmark = true

// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}

/*
 * Create a channel for input read files
 */
 Channel
       .fromFilePairs( reads_path, size: params.singleEnd ? 1 : 2 )
       .ifEmpty { exit 1, "Cannot find any reads matching: ${reads_path}\nNB: Please specify the folder and extension of the read files\nEg: --reads_folder reads --reads_extension fastq"}
       .set { reads }


 /*
  * targetDB files
  */
targetdb = file("${targetdb_folder}/targetDB")
targetdb_type = file("${targetdb_folder}/targetDB.dbtype")
targetdb_index = file("${targetdb_folder}/targetDB.index")
targetdb_lookup = file("${targetdb_folder}/targetDB.lookup")
targetdb_h = file("${targetdb_folder}/targetDB_h")
targetdb_h_index = file("${targetdb_folder}/targetDB_h.index")


// Header log info
log.info """=======================================================
                                         ,--./,-.
         ___     __   __   __   ___     /,-._.--~\'
   |\\ | |__  __ /  ` /  \\ |__) |__         }  {
   | \\| |       \\__, \\__/ |  \\ |___     \\`-._,-`-,
                                         `._,._,\'

PhilPalmer/onemetagenome
======================================================="""
def summary = [:]
summary['Pipeline Name']    = 'PhilPalmer/onemetagenome'
//summary['Reads folder']     = params.reads_folder
//summary['Reads extension']  = params.reads_extension
summary['Reads']            = reads_path
//summary['Fasta database']   = params.fas
summary['TargetDB directory'] = targetdb_folder
summary['Uniprot database'] = params.uniprot
summary['Taxdump']          = params.taxdump
summary['Output directory'] = params.outdir
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="


 /*
  * STEP 1 - Convert query database into mmseqs database format
  */
 process convertdb_query {
     container 'soedinglab/mmseqs2:latest'
     publishDir "${outdir}/tmp/createdb/query", mode: 'copy'

     input:
     //file "assembly.fas" from assembly
     set val(name), file(reads) from reads

     output:
     file "queryDB*" into queryDB

     script:
     """
     mmseqs createdb $reads queryDB
     """
 }

 /*
  * STEP 2 - Convert target database into mmseqs database format

 process convertdb_target {
     container 'soedinglab/mmseqs2:latest'
     publishDir "${outdir}/tmp/createdb/target", mode: 'copy'

     input:
     file fas

     output:
     file "targetDB*" into targetDB, targetDB2

     script:
     """
     mmseqs createdb $fas targetDB
     """
 }
 */

 /*
  * STEP 3 - Using uniprot data to generate targetDB.tsv for taxonomy (STEP 4)
  */
  process pre_taxonomy {
      container 'soedinglab/mmseqs2:latest'
      publishDir "${outdir}/tmp/taxonomy/pre_taxonomy", mode: 'copy'

      input:
      file uniprot
      file targetdb
      file targetdb_type
      file targetdb_index
      file targetdb_lookup
      file targetdb_h
      file targetdb_h_index

      output:
      file "targetDB.tsv" into tsv

      script:
      """
      # The targetDB.lookup file should be in the following format:
      # numeric-db-id tab-character UniProt-Accession (e.g. Q6GZX4)

      # UniRef has a prefixed accession (e.g. UniRef100_Q6GZX4)
      # Remove this prefix first:
      sed -i 's|UniRef100_||g' targetDB.lookup

      # Generate annotation mapping DB (target DB IDs to NCBI taxa, line type OX)
      mmseqs convertkb $uniprot targetDB.mapping --kb-columns OX --mapping-file targetDB.lookup
      # Reformat targetDB.mapping_OX DB into tsv file
      mmseqs prefixid targetDB.mapping_OX targetDB.mapping_OX_pref
      tr -d '\\000' < targetDB.mapping_OX_pref > targetDB.tsv_tmp

      # Cleanup: taxon format:  "NCBI_TaxID=418404 {ECO:0000313|EMBL:AHX25609.1};"
      # Only the numerical identifier "418404" is required.
      awk '{match(\$2, /=([^ ;]+)/, a); print \$1"\t"a[1]; }' targetDB.tsv_tmp > targetDB.tsv
      """
  }

  /*
   * STEP 4 - Executing the taxonomy classification
   */
  process taxonomy {
      container 'soedinglab/mmseqs2:latest'
      publishDir "${outdir}/tmp/taxonomy", mode: 'copy'

      input:
      file "*" from queryDB
      file "targetDB.tsv" from tsv
      file taxdump from taxdump
      file targetdb
      file targetdb_type
      file targetdb_index
      file targetdb_lookup
      file targetdb_h
      file targetdb_h_index

      output:
      set file("reads_number.txt"), file("queryLca.tsv"), file("queryLcaProt.tsv") into analysis, analysis2, analysis3

      script:
      """
      #reads_number="\$(wc -l queryDB.index | awk '{print \$1}')"
      wc -l queryDB.index | awk '{print \$1}' > reads_number.txt
      #doing a big taxdump
      mkdir ncbi-taxdump && mv taxdump.tar.gz ncbi-taxdump && cd ncbi-taxdump
      tar xzvf taxdump.tar.gz
      cd ..
      mmseqs taxonomy queryDB targetDB targetDB.tsv ncbi-taxdump queryLcaDB tmp
      mmseqs convertalis queryDB targetDB tmp/latest/2b_ali queryLcaProt.tsv
      rm -rf tmp
      mmseqs createtsv queryDB queryLcaDB queryLca.tsv
      """
  }

  /*
   * STEP 5 - Generating a phylogenetic tree using the R package taxize
   */
  process phylotree {
     container 'lifebitai/onemetagenome_phylotree:latest'
     publishDir "${outdir}/dont_delete_me", mode: 'copy'
     publishDir "${outdir}/tmp/post_taxonomy", pattern: 'table.csv', mode: 'copy'

     when:
     params.benchmark == false

     input:
     set file("reads_number.txt"), file("queryLca.tsv"), file("queryLcaProt.tsv") from analysis

     output:
     file "phylotree.jpeg"
     file "table.csv" into table
     //file "phylotree.pdf"
     //file "phylotree.png"

     script:
     """
     #make phylotree
     echo "ENTREZ_KEY='01f380df4cbfe85683d3ce7d1716648b3d09'" > .Renviron
     Rscript /data/rscripts/docker_onemetagenome_phylotree.r

     #make table
     mv queryLca.tsv no_header.tsv
     { echo -e "Query Accession\tLCA NCBI Taxon ID\tLCA Rank Name\tLCA Scientific Name"; cat no_header.tsv; } > queryLca.tsv
     cat queryLca.tsv | tr "\\t" "," > queryLca.csv
     Rscript /data/rscripts/table.r
     """
  }

  /*
   * STEP 6 - Generating the EC numbers, table and final output file
   */
  process output {
     container 'lifebitai/csv2html:latest'
     publishDir "${outdir}/tmp/post_taxonomy", pattern: 'ec2protein.tsv', mode: 'copy'
     publishDir "${outdir}/dont_delete_me", pattern: 'queryLca.html', mode: 'copy'
     publishDir "${outdir}", pattern: 'output.html', mode: 'copy'

     when:
     params.benchmark == false

     input:
     set file("reads_number.txt"), file("queryLca.tsv"), file("queryLcaProt.tsv") from analysis2
     file "table.csv" from table

     output:
     file "ec2protein.tsv" into ec2protein
     file "queryLca.html"
     file "output.html"

     script:
     """
     cp /data/Neo_Gene_EC_Map.py .
     cp /data/swiss_map.tsv .
     #get EC numbers
     python2 Neo_Gene_EC_Map.py swiss_map.tsv queryLcaProt.tsv ec2protein.tsv

     #make table
     mv table.csv queryLca.csv
     csvtotable queryLca.csv queryLca.html

     #get output
     cp /data/output.html .
     """
  }

  /*
   * STEP 7 - Generating Krona charts for taxonic and functional abundance
   */
  process chart {
     container 'lifebitai/onemetagenome_krona:latest'
     publishDir "${outdir}/dont_delete_me", mode: 'copy'

     when:
     params.benchmark == false

     input:
     set file("reads_number.txt"), file("queryLca.tsv"), file("queryLcaProt.tsv") from analysis3
     file "ec2protein.tsv" from ec2protein

     output:
     file "taxonomy.krona.html"
     file "ec.krona.html"

     script:
     """
     #taxonic abundance
     awk '{print \$1,"\\t",\$2}' queryLca.tsv > krona_queryLca.tsv
     ktImportTaxonomy krona_queryLca.tsv

     #functional abundance
     sed -i -e '159,163d;' /KronaTools-2.7/scripts/ImportEC.pl
     ktImportEC ec2protein.tsv
     """
  }
