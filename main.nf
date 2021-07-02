#!/usr/bin/env nextflow

params.outdir='output'

params.genotype_file='/net/seq/data/projects/regulotyping-h.CD3+/genotyping/output/calls/all.filtered.snps.annotated.vcf.gz'
params.genotypes_dir='/net/seq/data/projects/regulotyping-h.CD3+/genotyping/output/h5'

params.genome='/net/seq/data/genomes/human/GRCh38/noalts/GRCh38_no_alts'
nuclear_chroms = "$params.genome" + ".nuclear.txt"


//heterzygous filtering parameters
params.min_GQ=50 // Minimum genotype quality
params.min_DP=12 // Minimum read depth over SNP
params.min_AD=4 // Minimum reads per alleles


// DONORS = Channel.create()
// SAMPLES_AGGREGATIONS = Channel.create()

Channel
	.fromPath("/tmp/metadata.txt")
	.splitCsv(header:true, sep:'\t')
	.map{ row -> tuple( row.donor_id, row.ag_number, row.bamfile ) }
	.tap{ SAMPLES_AGGREGATIONS }
	.map{ it[0] }
	.unique()
	.tap{ DONORS }

// Make a heterozyguous sites file for each donor
// There some filtering at this step to make sure the genotype
// are reliable and informative

process het_sites {
	tag "${donor_id}"

	publishDir params.outdir + "/het_sites", mode: 'copy'

	queue 'queue1'

	input:
	val(donor_id) from DONORS
	file genotype_file from file("${params.genotype_file}")
	file '*' from file("${params.genotype_file}.csi")

	val min_DP from params.min_DP
	val min_AD from params.min_AD
	val min_GQ from params.min_GQ

	output:
	set val(donor_id), file("${donor_id}.bed.gz"), file("${donor_id}.bed.gz.tbi") into HET_SITES

	script:
	"""
	bcftools view \
		-s ${donor_id} ${genotype_file} \
	| bcftools query \
		-i'GT="het"' \
		-f"%CHROM\\t%POS0\\t%POS\\t%ID\\t%REF\\t%ALT\\t[%GQ\\t%AD{0}\\t%AD{1}\\t%DP]\\n" \
	| awk -v OFS="\\t" \
		-v min_GQ=${min_GQ} \
		-v min_AD=${min_AD} \
		-v min_DP=${min_DP} \
		'\$7>=min_GQ && \$8>=min_AD && \$9>=min_AD && \$10>=min_DP { \
			rsid=\$4; \
			\$4=\$1":"\$2":"\$5"/"\$6"\\t"rsid; \
			print; \
		}' \
	| sort-bed - \
	| bgzip -c \
	> ${donor_id}.bed.gz

	tabix -p bed ${donor_id}.bed.gz
	"""
}

process remap_bamfiles {
	tag "${donor_id}:AG${ag_number}"

	scratch true
	publishDir params.outdir + "/remapped", mode: 'copy'

	cpus 2
	module 'python/3.6.4'

	input:
	set val(donor_id), val(ag_number), val(bam_file) from SAMPLES_AGGREGATIONS
	val genotypes_dir from params.genotypes_dir

	file genome from file(params.genome)
	file '*' from file("${params.genome}.amb")
	file '*' from file("${params.genome}.ann")
	file '*' from file("${params.genome}.bwt")
	file '*' from file("${params.genome}.fai")
	file '*' from file("${params.genome}.pac")
	file '*' from file("${params.genome}.sa")

	file nuclear_chroms from file(nuclear_chroms)

	file genotypes_snp_tab from file("${params.genotypes_dir}/snp_tab.h5")
	file genotypes_snp_index from file("${params.genotypes_dir}/snp_index.h5")
	file genotypes_haplotypes from file("${params.genotypes_dir}/haplotypes.h5")
	
	output:
	set val(donor_id), val(ag_number), file("${ag_number}.bam"), file("${ag_number}.bam.bai"), file("${ag_number}.passing.bam"), file ("${ag_number}.passing.bam.bai") into REMAPPED_READS

	script:
	"""
	## step 1 -- remove duplicates
	##

	python3 /home/jvierstra/.local/src/WASP/mapping/rmdup_pe.py \
		${bam_file} reads.rmdup.bam

	samtools sort \
		-m ${task.memory.toMega()}M \
		-@${task.cpus} \
		-o reads.rmdup.sorted.bam \
		-O bam \
		reads.rmdup.bam

	## step 2 -- get reads overlapping a SNV
	##

	python3 /home/jvierstra/.local/src/WASP/mapping/find_intersecting_snps.py \
		--is_paired_end \
		--is_sorted \
		--output_dir \${PWD} \
		--snp_tab ${genotypes_snp_tab} \
		--snp_index ${genotypes_snp_index} \
		--haplotype ${genotypes_haplotypes}\
		--samples ${donor_id} \
		reads.rmdup.sorted.bam

	## step 3 -- re-align reads
	##

	bwa aln -Y -l 32 -n 0.04 -t ${task.cpus} ${genome} \
		reads.rmdup.sorted.remap.fq1.gz \
	> reads.rmdup.sorted.remap.fq1.sai

	bwa aln -Y -l 32 -n 0.04 -t ${task.cpus} ${genome} \
		reads.rmdup.sorted.remap.fq2.gz \
	> reads.rmdup.sorted.remap.fq2.sai

	bwa sampe -n 10 -a 750 \
		${genome} \
		reads.rmdup.sorted.remap.fq1.sai reads.rmdup.sorted.remap.fq2.sai \
		reads.rmdup.sorted.remap.fq1.gz reads.rmdup.sorted.remap.fq2.gz \
	| samtools view -b -t ${genome}.fai - \
	> reads.remapped.bam

	## step 4 -- mark QC flag
	##

	python3 /home/solexa/stampipes/scripts/bwa/filter_reads.py \
		reads.remapped.bam \
		reads.remapped.marked.bam \
		${nuclear_chroms}

	## step 5 -- filter reads

	samtools sort \
		-m ${task.memory.toMega()}M \
		-@${task.cpus} -l0 reads.remapped.marked.bam \
	| samtools view -b -F 512 - \
	> reads.remapped.marked.filtered.bam

	python3 /home/jvierstra/.local/src/WASP/mapping/filter_remapped_reads.py \
		reads.rmdup.sorted.to.remap.bam \
		reads.remapped.marked.filtered.bam \
		reads.remapped.keep.bam

	## step 6 -- merge back reads
	samtools merge -f \
		reads.passing.bam \
		reads.remapped.keep.bam \
		reads.rmdup.sorted.keep.bam

	samtools sort \
		-m ${task.memory.toMega()}M \
		-@${task.cpus} \
		-o reads.passing.sorted.bam  \
		reads.passing.bam

	mv reads.rmdup.sorted.bam ${ag_number}.bam
	samtools index ${ag_number}.bam

	mv reads.passing.sorted.bam ${ag_number}.passing.bam
	samtools index ${ag_number}.passing.bam

	"""
}

REMAPPED_READS
	.combine(HET_SITES, by: 0)
	.set{ REMAPPED_READS_INDIV }

process count_reads {
	tag "${donor_id}:${ag_number}"

	publishDir params.outdir + "/count_reads", mode: 'copy'

	module 'python/3.6.4'

	input:
	set val(donor_id), val(ag_number), file(bam_all_file), file(bam_all_index_file), file(bam_passing_file), file(bam_passing_index_file), file(het_sites_file), file(het_sites_index_file) from REMAPPED_READS_INDIV

	output:
	set val(donor_id), val(ag_number), file("${ag_number}.bed.gz"), file("${ag_number}.bed.gz.tbi") into COUNT_READS

	script:
	"""
	python3 /net/seq/data/projects/regulotyping-h.CD3+/count_tags_pileup.py \
		${het_sites_file} ${bam_all_file} ${bam_passing_file} \
	| sort-bed - | bgzip -c > ${ag_number}.bed.gz

	tabix -p bed ${ag_number}.bed.gz
	"""
}

COUNT_READS.into{ COUNT_READS_LIST; COUNT_READS_FILES }

COUNT_READS_LIST
	.map{ [it[1], it[0], it[2].name].join("\t") }
	.collectFile(
		name: 'sample_map.tsv', 
		newLine: true
	)
	.first()
	.set{RECODE_VCF_SAMPLE_MAP_FILE}

COUNT_READS_FILES
	.flatMap{ [file(it[2]), file(it[3])] }
	.set{ COUNT_READS_ALL_FILES }

process recode_vcf {
	publishDir params.outdir + "/vcf", mode: 'copy'

	module 'python/3.6.4'

	input:
	file 'sample_map.tsv' from RECODE_VCF_SAMPLE_MAP_FILE
	file '*' from COUNT_READS_ALL_FILES.collect()

	file vcf_file from file("${params.genotype_file}")
	file '*' from file("${params.genotype_file}.csi")

	output:
	file 'allele_counts.vcf.gz*'

	script:
	"""
	recode_vcf.py \
		${vcf_file} \
		sample_map.tsv \
		allele_counts.vcf

	bgzip -c allele_counts.vcf > allele_counts.vcf.gz
	bcftools index allele_counts.vcf.gz

	"""
}
