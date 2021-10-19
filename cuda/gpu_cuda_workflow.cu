
// Standard utilities and common systems includes
#include "kernels.cuh"
#include "cpu_functions.c"
#include "cub/cub.cuh"
#include <moderngpu/kernel_mergesort.hxx>
#include <cuda_profiler_api.h>

#define BILLION 1000 * 1000 * 1000;


////////////////////////////////////////////////////////////////////////////////
// Program main
////////////////////////////////////////////////////////////////////////////////


void print_header(FILE * out, uint32_t query_len, uint32_t ref_len);
uint64_t memory_allocation_chooser(uint64_t total_memory);
char * dump_memory_region(char * ptr_pointer, uint64_t size);

int main(int argc, char ** argv)
{
    clock_t start = clock(), end = clock();
#ifdef SHOWTIME
    struct timespec HD_start, HD_end;
    uint64_t time_seconds = 0, time_nanoseconds = 0;
#endif
    uint32_t i, min_length = 64, max_frequency = 0, n_frags_per_block = 32;
    float factor = 0.15;
    int fast = 0; // sensitive is default
    unsigned selected_device = 0;
    FILE * query = NULL, * ref = NULL, * out = NULL;
    init_args(argc, argv, &query, &selected_device, &ref, &out, &min_length, &fast, &max_frequency, &factor, &n_frags_per_block);

    //cudaProfilerStart();

#ifdef AVX512CUSTOM
    fprintf(stdout, "[INFO] Using AVX512 intrinsics. If not available, recompile the program after removing -DAVX512CUSTOM in the Makefile\n");
#endif
    ////////////////////////////////////////////////////////////////////////////////
    // Get info of devices
    ////////////////////////////////////////////////////////////////////////////////

    int ret_num_devices;
    //unsigned compute_units;
    uint64_t global_device_RAM;
    //int work_group_size_local;
    int ret;
    
    // Query how many devices there are
    if(cudaSuccess != (ret = cudaGetDeviceCount(&ret_num_devices))){ fprintf(stderr, "Failed to query number of devices\n"); exit(-1); }

    cudaDeviceProp device;

    for(i=0; i<ret_num_devices; i++){
        if( cudaSuccess != (ret = cudaGetDeviceProperties(&device, i))){ fprintf(stderr, "Failed to get cuda device property: %d\n", ret); exit(-1); }
        fprintf(stdout, "\tDevice [%" PRIu32"]: %s\n", i, device.name);
        global_device_RAM = device.totalGlobalMem;
        fprintf(stdout, "\t\tGlobal mem   : %" PRIu64" (%" PRIu64" MB)\n", global_device_RAM, global_device_RAM / (1024*1024));
        //compute_units = device.multiProcessorCount;
        //fprintf(stdout, "\t\tCompute units: %" PRIu64"\n", (uint64_t) compute_units);
        //work_group_size_local = device.maxThreadsPerBlock;
        //fprintf(stdout, "\t\tMax work group size: %d\n", work_group_size_local);
        //fprintf(stdout, "\t\tWork size dimensions: (%d, %d, %d)\n", work_group_dimensions[0], work_group_dimensions[1], work_group_dimensions[2]);
        //fprintf(stdout, "\t\tWarp size: %d\n", device.warpSize);
        //fprintf(stdout, "\t\tGrid dimensions: (%d, %d, %d)\n", device.maxGridSize[0], device.maxGridSize[1], device.maxGridSize[2]);
    }
    //selected_device = 3; // REMOVE --- ONLY FOR TESTING $$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$$

    if( cudaSuccess != (ret = cudaSetDevice(selected_device))){ fprintf(stderr, "Failed to get cuda device property: %d\n", ret); exit(-1); }
    fprintf(stdout, "[INFO] Using device %d\n", selected_device);



    if( cudaSuccess != (ret = cudaGetDeviceProperties(&device, selected_device))){ fprintf(stderr, "Failed to get cuda device property: %d\n", ret); exit(-1); }
    global_device_RAM = device.totalGlobalMem;

    
    end = clock();
#ifdef SHOWTIME
    fprintf(stdout, "[INFO] INIT 1 t=%f\n", (float)(end - start) / CLOCKS_PER_SEC);
#endif

    start = clock();

    // Calculate how much ram we can use for every chunk
    uint64_t effective_global_ram =  (global_device_RAM - memory_allocation_chooser(global_device_RAM)); //Minus 100 to 300 MBs for other stuff

    // We will do the one-time alloc here
    // i.e. allocate a pool once and used it manually

    char * data_mem;

    // One workload depends on number of words (words + sortwords + generate hits)
    // The other one depends on number of hits (sort hits + filterhits + frags)

    // [TODO] the rework on hits memory allocation
    // It used to be 8+8+4+4 now its only the 8

    if(fast == 2) factor = 0.45;
    else if(fast == 1) factor = 0.45;
    uint64_t bytes_for_words = (factor * effective_global_ram); // 512 MB for words
    uint64_t words_at_once = bytes_for_words / (8+8+4+4); 
    // We have to subtract the bytes for words as well as the region for storing the DNA sequence
    uint64_t max_hits = (effective_global_ram - bytes_for_words - words_at_once) / (2*8);
    uint64_t bytes_to_subtract = max_hits * 8;




    //ret = cudaMalloc(&data_mem, (effective_global_ram - bytes_to_subtract) * sizeof(char)); 
    ret = cudaMalloc(&data_mem, (effective_global_ram) * sizeof(char)); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pool memory in device. Error: %d\n", ret); exit(-1); }
    fprintf(stdout, "[INFO] Memory pool at %p of size %lu bytes\n", data_mem, (effective_global_ram) * sizeof(char));


    char * pre_alloc = &data_mem[effective_global_ram - bytes_to_subtract]; // points to the last section of the big pool
    //ret = cudaMalloc(&pre_alloc, (bytes_to_subtract) * sizeof(char));
    //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate auxiliary pool memory in device. Error: %d\n", ret); exit(-1); }

    fprintf(stdout, "[INFO] You can have %" PRIu64" MB for words (i.e. %" PRIu64" words), and %" PRIu64" MB for hits (i.e. %" PRIu64" hits)\n", 
        bytes_for_words / (1024*1024), words_at_once, (effective_global_ram - bytes_for_words - words_at_once) / (1024*1024), max_hits);

    fprintf(stdout, "[INFO] Filtering at a minimum length of %" PRIu32" bps\n", min_length);
    if(fast == 1) 
        fprintf(stdout, "[INFO] Running on fast mode (some repetitive seeds will be skipped)\n");
    else if(fast == 2)
        fprintf(stdout, "[INFO] Running on hyper fast mode (some repetitive seeds will be skipped)\n");
    else
        fprintf(stdout, "[INFO] Running on sensitive mode (ALL seeds are computed [mf:%" PRIu32"])\n", max_frequency);

   
    // Allocate memory pool in GPU and pass it to moderngpu
    Mem_pool mptr;
    mptr.mem_ptr = pre_alloc;
    mptr.address = 0;
    mptr.limit = bytes_to_subtract;
    mgpu::standard_context_t context(false, 0, &mptr);
    //mgpu::standard_context_t context(false, 0, NULL);

    
    // Set working size
    size_t threads_number = 32;
    size_t number_of_blocks;
    //cudaDeviceSetSharedMemConfig(cudaSharedMemBankSizeEightByte); // NOTICE: MAXWELL ignores this--

    

    // Inspect shared memory configuration
    //cudaSharedMemConfig shared_mem_conf;
    //ret = cudaDeviceGetSharedMemConfig(&shared_mem_conf);
    //if(ret != cudaSuccess){ fprintf(stdout, "[WARNING] Could not get shared memory configuration. Error: %d\n", ret); }
    //else { fprintf(stdout, "[INFO] Shared memory configuration is: %s\n", (shared_mem_conf == cudaSharedMemBankSizeFourByte) ? ("4 bytes") : ("8 bytes")); }

    // Load DNA sequences
    //uint32_t query_len = get_seq_len(query);
    //uint32_t ref_len = get_seq_len(ref);

    // This adds real rev time
#ifdef SHOWTIME
    clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif

    // Load faster
    fseek(query, 0L, SEEK_END);
    uint32_t coarse_query_len = (uint32_t) ftell(query);
    rewind(query);
    char * s_buffer = (char *) malloc(coarse_query_len * sizeof(char)); if(s_buffer == NULL) {fprintf(stderr, "Bad loading buffer (1)\n"); exit(-1);}
    char * pro_q_buffer = (char *) malloc(coarse_query_len * sizeof(char));  if(pro_q_buffer == NULL) {fprintf(stderr, "Bad loading buffer (2)\n"); exit(-1);}
    uint32_t read_bytes = (uint32_t) fread(s_buffer, 1, coarse_query_len, query); if(read_bytes < coarse_query_len) {fprintf(stderr, "Bad bytes reading (1)\n"); exit(-1);}
    uint32_t query_len = from_ram_load(s_buffer, pro_q_buffer, coarse_query_len);

    free(s_buffer);

    fseek(ref, 0L, SEEK_END);
    uint32_t coarse_ref_len = (uint32_t) ftell(ref);
    rewind(ref);
    s_buffer = (char *) malloc(coarse_ref_len * sizeof(char));  if(s_buffer == NULL) {fprintf(stderr, "Bad loading buffer (3)\n"); exit(-1);}
    char * pro_r_buffer = (char *) malloc(coarse_ref_len * sizeof(char));  if(pro_r_buffer == NULL) {fprintf(stderr, "Bad loading buffer (4)\n"); exit(-1);}
    read_bytes = (uint32_t) fread(s_buffer, 1, coarse_ref_len, ref); if(read_bytes < coarse_ref_len) {fprintf(stderr, "Bad bytes reading (2)\n"); exit(-1);}
    uint32_t ref_len = from_ram_load(s_buffer, pro_r_buffer, coarse_ref_len);

    free(s_buffer);

    // This adds real rev time
#ifdef SHOWTIME
    clock_gettime(CLOCK_MONOTONIC, &HD_end);
    time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
    time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
#endif


    
    fprintf(stdout, "[INFO] Qlen: %" PRIu32"; Rlen: %" PRIu32"\n", query_len, ref_len);




    // Check that sequence length complies
    if(MAX(query_len, ref_len) >= 2147483648){
        fprintf(stdout, "[WARNING] !!!!!!!!!!!!!!!!!!!!!!\n");
        fprintf(stdout, "[WARNING] PLEASE READ CAREFULLY\n");
        fprintf(stdout, "[WARNING] THE INPUT SEQUENCES ARE TOO LONG (MAX LEN 2147483648)\n");
        fprintf(stdout, "[WARNING] THE PROGRAM WILL CONTINUE TO WORK BUT MIGHT PRODUCE SOME ERRORS\n");
        fprintf(stdout, "[WARNING] THESE CAN APPEAR PARTICULARLY IN THE LIMITS OF THE SEQUENCE\n");
        fprintf(stdout, "[WARNING] CHECK THIS ISSUE ON A DOTPLOT\n");
        fprintf(stdout, "[WARNING] !!!!!!!!!!!!!!!!!!!!!!\n");
    }

    // Create variables to load up sequences using PINNED MEMORY to increase transfer rate
    //char * query_seq_host = (char *) malloc(query_len * sizeof(char));
    //char * ref_seq_host = (char *) malloc(ref_len * sizeof(char));
    //char * ref_rev_seq_host = (char *) malloc(ref_len * sizeof(char));

    // How about one big alloc (save ~3 seconds on mallocs)
    char * host_pinned_mem, * base_ptr_pinned;

    // [TODO] revisit all pinned memory 
    
    uint64_t pinned_bytes_on_host = words_at_once * (sizeof(uint64_t) * (2) + sizeof(uint32_t) * (2));
    pinned_bytes_on_host = pinned_bytes_on_host + max_hits * (sizeof(uint64_t) * (1) + sizeof(uint32_t) * (8));
    pinned_bytes_on_host = pinned_bytes_on_host + sizeof(char) * (query_len + 2*ref_len);
    pinned_bytes_on_host += 1024*1024; // Adding 1 MB for the extra padding in the realignments
    uint64_t pinned_address_checker = 0;


    fprintf(stdout, "[INFO] Allocating on host %" PRIu64" bytes (i.e. %" PRIu64" MBs)\n", pinned_bytes_on_host, pinned_bytes_on_host / (1024*1024));
    ret = cudaHostAlloc(&host_pinned_mem, pinned_bytes_on_host, cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for pool. Error: %d\n", ret); exit(-1); }
    
#ifdef SHOWTIME
    clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif
    char * query_seq_host, * ref_seq_host, * ref_rev_seq_host;
    base_ptr_pinned = (char *) &host_pinned_mem[0];
    query_seq_host = (char *) &host_pinned_mem[0];
    pinned_address_checker = realign_address(pinned_address_checker + query_len, 4);

    ref_seq_host = (char *) (base_ptr_pinned + pinned_address_checker);
    pinned_address_checker = realign_address(pinned_address_checker + ref_len, 4);

    ref_rev_seq_host = (char *) (base_ptr_pinned + pinned_address_checker);
    pinned_address_checker = realign_address(pinned_address_checker + ref_len, 4);
   
    //printf("Reverse starts at %p\n", ref_rev_seq_host); 


    
    //ret = cudaHostAlloc(&query_seq_host, query_len * sizeof(char), cudaHostAllocMapped); 
    //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for query_seq host. Error: %d\n", ret); exit(-1); }
    //ret = cudaHostAlloc(&ref_seq_host, ref_len * sizeof(char), cudaHostAllocMapped); 
    //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for ref_seq host. Error: %d\n", ret); exit(-1); }
    //ret = cudaHostAlloc(&ref_rev_seq_host, ref_len * sizeof(char), cudaHostAllocMapped); 
    //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for reverse ref_seq host. Error: %d\n", ret); exit(-1); }
    

    

    //cudaHostAlloc((void**)&a,n*sizeof(a),cudaHostAllocDefault);

    if(query_seq_host == NULL || ref_seq_host == NULL || ref_rev_seq_host == NULL) terror("Could not allocate memory for sequences in host");

    ////////////////////////////////////////////////////////////////////////////////
    // Read sequences and reverse the reference
    ////////////////////////////////////////////////////////////////////////////////

    // Create streams to allow concurrent copy and execute

    uint32_t n_streams = 4;
    cudaStream_t streams[n_streams];

    for(i=0; i<n_streams; i++) cudaStreamCreate(&streams[i]);

    // Pointer to device memory allocating the query sequence, reference and reversed reference

    fprintf(stdout, "[INFO] Loading query\n");
    //load_seq(query, query_seq_host);
    memcpy(query_seq_host, pro_q_buffer, query_len);
    fprintf(stdout, "[INFO] Loading reference\n");

    //load_seq(ref, ref_seq_host);
    memcpy(ref_seq_host, pro_r_buffer, ref_len);
    fprintf(stdout, "[INFO] Reversing reference\n");

    free(pro_q_buffer);
    free(pro_r_buffer);
    
    /*
    ret = cudaMalloc(&seq_dev_mem_reverse_aux, ref_len * sizeof(char)); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for reverse reference sequence in device (Attempted %" PRIu32" bytes) at reversing. Error: %d\n", (uint32_t) (ref_len * sizeof(char)), ret); exit(-1); }
    */

    // ## POINTER SECTION 0
    uint64_t address_checker = 0;
    
    char * ptr_seq_dev_mem_aux = &data_mem[0];
    address_checker = realign_address(address_checker + ref_len, 128);
    char * ptr_seq_dev_mem_reverse_aux = &data_mem[address_checker];
    address_checker = realign_address(address_checker + ref_len, 4);

    char * ptr_reverse_write[n_streams];

    uint32_t chunk_size = ref_len/n_streams + 4; // Always force one divisor more cause of decimal loss
    if(chunk_size % 128 != 0){ chunk_size += 128 - (chunk_size % 128); } // Since sequence starts at 0, making the chunks multiple of 128 guarantees 100% GL efficiency


    ptr_reverse_write[0] = ptr_seq_dev_mem_reverse_aux;
    for(i=1; i<n_streams-1; i++){
        ptr_reverse_write[i] = ptr_reverse_write[i-1] + chunk_size;
    }
    ptr_reverse_write[n_streams-1] = ptr_reverse_write[n_streams-2] + chunk_size;
    uintptr_t where_ends = (uintptr_t) (ptr_reverse_write[n_streams-1] + MIN(chunk_size, ref_len - chunk_size*(n_streams-1)));
    if(where_ends % 128 != 0) ptr_reverse_write[n_streams-1] += 128 - (where_ends % 128);

    //printf("Starts %p Endings %p\n", ptr_reverse_write[0], ptr_reverse_write[0]+chunk_size);
    //printf("Starts %p Endings %p\n", ptr_reverse_write[1], ptr_reverse_write[1]+chunk_size);
    //printf("Starts %p Endings %p\n", ptr_reverse_write[2], ptr_reverse_write[2]+chunk_size);
    //printf("Starts %p Endings %p\n", ptr_reverse_write[3], ptr_reverse_write[3]+MIN(chunk_size, ref_len - chunk_size*(n_streams-1)));
   

 
    threads_number = 128;
    //threads_number = 32;
    if(ref_len > 1024){
    

        number_of_blocks = chunk_size/threads_number + threads_number; // Same
        if(number_of_blocks % threads_number != 0){ number_of_blocks += 1; }
        uint32_t offset; //, inverse_offset;

        
        for(i=0; i<n_streams; i++)
        {
            offset = chunk_size * i;
            //inverse_offset = (chunk_size * (i+1) < ref_len) ? ref_len - chunk_size * (i+1) : 0;

            ret = cudaMemcpyAsync(ptr_seq_dev_mem_aux + offset, ref_seq_host + offset, MIN(chunk_size, ref_len - offset), cudaMemcpyHostToDevice, streams[i]);
            if(ret != cudaSuccess){ fprintf(stderr, "Could not copy reference sequence to device for reversing. Error: %d\n", ret); exit(-1); }

            //printf("On the other hand, the load align %p\n", ptr_seq_dev_mem_aux + offset);

            //cudaProfilerStart();
            kernel_reverse_complement<<<number_of_blocks, threads_number, 0, streams[i]>>>(ptr_seq_dev_mem_aux + offset, ptr_reverse_write[i], MIN(chunk_size, ref_len - offset));
            //cudaProfilerStop();

        }

        ret = cudaDeviceSynchronize();
        if(ret != cudaSuccess){ fprintf(stderr, "Could not compute reverse on reference. Error: %d\n", ret); exit(-1); }

        // Perform copy from the nstreams
        uint32_t t_copy_rev = 0;
        for(i=0; i<n_streams; i++){

            ret = cudaMemcpy(ref_rev_seq_host + t_copy_rev, ptr_reverse_write[n_streams - (i+1)], MIN(chunk_size, ref_len - chunk_size*(n_streams-1-i)), cudaMemcpyDeviceToHost);
            if(ret != cudaSuccess){ fprintf(stderr, "Could not copy reference sequence to device for reversing. Error: %d\n", ret); exit(-1); }
            t_copy_rev += MIN(chunk_size, ref_len - chunk_size*(n_streams-1-i));
        }



    }else{


        number_of_blocks = (ref_len)/threads_number + 1;


        uintptr_t integer_ptr = (uintptr_t) ptr_seq_dev_mem_reverse_aux;
        uint64_t ptr_end = ((uint64_t) integer_ptr) + ref_len;
    
        if(ptr_end % 128 != 0) ptr_seq_dev_mem_reverse_aux += 128 - (ptr_end % 128);



        ret = cudaMemcpy(ptr_seq_dev_mem_aux, ref_seq_host, ref_len, cudaMemcpyHostToDevice);
        if(ret != cudaSuccess){ fprintf(stderr, "Could not copy reference sequence to device for reversing. Error: %d\n", ret); exit(-1); }
        //cudaProfilerStart();
        kernel_reverse_complement<<<number_of_blocks, threads_number>>>(ptr_seq_dev_mem_aux, ptr_seq_dev_mem_reverse_aux, ref_len);
        //cudaProfilerStop();
        
        ret = cudaDeviceSynchronize();
        if(ret != cudaSuccess){ fprintf(stderr, "Could not compute reverse on reference. Error: %d\n", ret); exit(-1); }

        ret = cudaMemcpy(ref_rev_seq_host, ptr_seq_dev_mem_reverse_aux, ref_len, cudaMemcpyDeviceToHost);
        if(ret != cudaSuccess){ fprintf(stderr, "Could not copy reference sequence to device for reversing. Error: %d\n", ret); exit(-1); }
    }
    
    threads_number = 32;



    /*

    }
    */


    ret = cudaDeviceSynchronize();
    

    //cudaFree(seq_dev_mem_aux);
    //cudaFree(seq_dev_mem_reverse_aux);

    //for(i=0; i<ref_len; i++){
    //    if(isupper(ref_rev_seq_host[i]) != ref_rev_seq_host[i]) {
    //        printf("Found first at %u and it is %.32s\n", i, &ref_rev_seq_host[i]); break;
    //    }
    //}

    // Print some info
#ifdef SHOWTIME
    end = clock();
    clock_gettime(CLOCK_MONOTONIC, &HD_end);
    time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
    time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
    time_seconds *= BILLION;
    fprintf(stdout, "[INFO] rev comp t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
    time_seconds = 0;
    time_nanoseconds = 0;
#endif 

#ifdef SHOWTIME
    clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif

    fprintf(stdout, "[INFO] Showing start of reference sequence:\n");
    
    fprintf(stdout, "\t(Begin ref)%.64s\n", ref_seq_host);
    fprintf(stdout, "\t(Begin rev)%.64s\n", ref_rev_seq_host);
    fprintf(stdout, "\t(End   ref)%.64s\n", &ref_seq_host[ref_len-64]);
    fprintf(stdout, "\t(End   rev)%.64s\n", &ref_rev_seq_host[ref_len-64]);

     
    //fprintf(stdout, "\t(Full que)%.*s\n", query_len, query_seq_host);
    //fprintf(stdout, "\t(Full ref)%.*s\n", ref_len, ref_seq_host);
    //fprintf(stdout, "\t(Full rev)%.*s\n", ref_len, ref_rev_seq_host);


    // Write header to CSV
    print_header(out, query_len, ref_len);

    ////////////////////////////////////////////////////////////////////////////////
    // Allocation of pointers
    ////////////////////////////////////////////////////////////////////////////////


    // Allocate memory in host to download kmers and store hits
    
    uint64_t * dict_x_keys, * dict_y_keys; // Keys are hashes (64-b), values are positions (32)
    uint32_t * dict_x_values, * dict_y_values;

    pinned_address_checker = realign_address(pinned_address_checker, 8);
    dict_x_keys = (uint64_t *) (base_ptr_pinned + pinned_address_checker);
    pinned_address_checker = realign_address(pinned_address_checker + words_at_once * sizeof(uint64_t), 4);

    dict_x_values = (uint32_t *) (base_ptr_pinned + pinned_address_checker);
    pinned_address_checker = realign_address(pinned_address_checker + words_at_once * sizeof(uint32_t), 8);

    dict_y_keys = (uint64_t *) (base_ptr_pinned + pinned_address_checker);
    pinned_address_checker = realign_address(pinned_address_checker + words_at_once * sizeof(uint64_t), 4);

    dict_y_values = (uint32_t *) (base_ptr_pinned + pinned_address_checker);
    pinned_address_checker = realign_address(pinned_address_checker + words_at_once * sizeof(uint32_t), 4);
    // These depends on the number of words
    /*
    //dict_x_keys = (uint64_t *) malloc(words_at_once*sizeof(uint64_t));
    ret = cudaHostAlloc(&dict_x_keys, words_at_once * sizeof(uint64_t), cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for dict_x_keys. Error: %d\n", ret); exit(-1); }
    //dict_x_values = (uint32_t *) malloc(words_at_once*sizeof(uint32_t));
    ret = cudaHostAlloc(&dict_x_values, words_at_once * sizeof(uint32_t), cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for dict_x_values. Error: %d\n", ret); exit(-1); }
    //if(dict_x_keys == NULL || dict_x_values == NULL) { fprintf(stderr, "Allocating for kmer download in query. Error: %d\n", ret); exit(-1); }
    //dict_y_keys = (uint64_t *) malloc(words_at_once*sizeof(uint64_t));
    ret = cudaHostAlloc(&dict_y_keys, words_at_once * sizeof(uint64_t), cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for dict_y_keys. Error: %d\n", ret); exit(-1); }
    //dict_y_values = (uint32_t *) malloc(words_at_once*sizeof(uint32_t));
    ret = cudaHostAlloc(&dict_y_values, words_at_once * sizeof(uint32_t), cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for dict_y_values. Error: %d\n", ret); exit(-1); }
    //if(dict_y_keys == NULL || dict_y_values == NULL) { fprintf(stderr, "Allocating for kmer download in ref. Error: %d\n", ret); exit(-1); }
    */

    

    
    // These are now depending on the number of hits
    Hit * hits;
    uint32_t * filtered_hits_x, * filtered_hits_y;
    /*
    //Hit * hits = (Hit *) malloc(max_hits*sizeof(Hit));
    Hit * hits;
    ret = cudaHostAlloc(&hits, max_hits * sizeof(Hit), cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for hits. Error: %d\n", ret); exit(-1); }

    //uint32_t * filtered_hits_x = (uint32_t *) malloc(max_hits*sizeof(uint32_t));
    uint32_t * filtered_hits_x;
    ret = cudaHostAlloc(&filtered_hits_x, max_hits * sizeof(uint32_t), cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for filtered_hits_x. Error: %d\n", ret); exit(-1); }

    //uint32_t * filtered_hits_y = (uint32_t *) malloc(max_hits*sizeof(uint32_t));
    uint32_t * filtered_hits_y;
    ret = cudaHostAlloc(&filtered_hits_y, max_hits * sizeof(uint32_t), cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for filtered_hits_y. Error: %d\n", ret); exit(-1); }
    */

    pinned_address_checker = realign_address(pinned_address_checker, 8);
    hits = (Hit *) (base_ptr_pinned + pinned_address_checker);
    pinned_address_checker = realign_address(pinned_address_checker + max_hits * sizeof(Hit), 4);

    filtered_hits_x = (uint32_t *) (base_ptr_pinned + pinned_address_checker);
    pinned_address_checker = realign_address(pinned_address_checker + max_hits * sizeof(uint32_t), 4);

    filtered_hits_y = (uint32_t *) (base_ptr_pinned + pinned_address_checker);
    pinned_address_checker = realign_address(pinned_address_checker + max_hits * sizeof(uint32_t), 4);


    uint32_t * host_left_offset,  * host_right_offset;//, * ascending_numbers; //, * indexing_numbers; // Disabled since the ascending numbers are not used anymore
    uint64_t * diagonals;
    /*
    // These are for the device
    uint32_t * device_filt_hits_x, * device_filt_hits_y, * left_offset, * right_offset;

    //uint32_t * host_left_offset = (uint32_t *) malloc(max_hits*sizeof(uint32_t));
    uint32_t * host_left_offset;
    ret = cudaHostAlloc(&host_left_offset, max_hits * sizeof(uint32_t), cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for host_left_offset. Error: %d\n", ret); exit(-1); }

    //uint32_t * host_right_offset = (uint32_t *) malloc(max_hits*sizeof(uint32_t));
    uint32_t * host_right_offset;
    ret = cudaHostAlloc(&host_right_offset, max_hits * sizeof(uint32_t), cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for host_right_offset. Error: %d\n", ret); exit(-1); }

    //if(host_left_offset == NULL || host_right_offset == NULL) terror("Could not allocate host offsets");
    //if(hits == NULL || filtered_hits_x == NULL || filtered_hits_y == NULL) terror("Could not allocate hits");

    //uint64_t * diagonals = (uint64_t *) malloc(max_hits*sizeof(uint64_t));
    uint64_t * diagonals;
    ret = cudaHostAlloc(&diagonals, max_hits * sizeof(uint64_t), cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for diagonals. Error: %d\n", ret); exit(-1); }

    //uint64_t * device_diagonals, * device_diagonals_buf;
    //uint32_t * device_hits, * device_hits_buf; // These will actually be just indices to redirect the hits sorting

    //uint32_t * ascending_numbers = (uint32_t *) malloc(max_hits*sizeof(uint32_t)); for(i=0; i<max_hits; i++) ascending_numbers[i] = i;
    uint32_t * ascending_numbers;
    ret = cudaHostAlloc(&ascending_numbers, max_hits * sizeof(uint32_t), cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for ascending numbers. Error: %d\n", ret); exit(-1); }
    for(i=0; i<max_hits; i++) ascending_numbers[i] = i;

    //uint32_t * indexing_numbers = (uint32_t *) malloc(max_hits*sizeof(uint32_t));
    uint32_t * indexing_numbers;
    ret = cudaHostAlloc(&indexing_numbers, max_hits * sizeof(uint32_t), cudaHostAllocMapped); 
    if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pinned memory for indexing numbers. Error: %d\n", ret); exit(-1); }
    
    //if(hits == NULL) { fprintf(stderr, "Allocating for hits download. Error: %d\n", ret); exit(-1); }
    */

    pinned_address_checker = realign_address(pinned_address_checker, 4);
    host_left_offset = (uint32_t *) (base_ptr_pinned + pinned_address_checker);
    pinned_address_checker = realign_address(pinned_address_checker + max_hits * sizeof(uint32_t), 4);

    host_right_offset = (uint32_t *) (base_ptr_pinned + pinned_address_checker);
    pinned_address_checker = realign_address(pinned_address_checker + max_hits * sizeof(uint32_t), 8);

    diagonals = (uint64_t *) (base_ptr_pinned + pinned_address_checker);
    pinned_address_checker = realign_address(pinned_address_checker + max_hits * sizeof(uint64_t), 4);

    //ascending_numbers = (uint32_t *) (base_ptr_pinned + pinned_address_checker);
    //pinned_address_checker = realign_address(pinned_address_checker + max_hits * sizeof(uint32_t), 4);
    //for(i=0; i<max_hits; i++) ascending_numbers[i] = i;

    // Disabled since the ascending numbers are not used anymore in reality
    //indexing_numbers = (uint32_t *) (base_ptr_pinned + pinned_address_checker);
    //pinned_address_checker = realign_address(pinned_address_checker + max_hits * sizeof(uint32_t), 4);


    
    //printf("ALOHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA------------------------ remove thisssssssssssssssssssssssssssssssssssssssssss\n");
    //cudaFree(data_mem);


    ////////////////////////////////////////////////////////////////////////////////
    // Read the query and reference in blocks
    ////////////////////////////////////////////////////////////////////////////////
#ifdef SHOWTIME
    clock_gettime(CLOCK_MONOTONIC, &HD_end);
    time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
    time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
    time_seconds *= BILLION;
    fprintf(stdout, "[INFO] INIT 3 t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
    time_seconds = 0;
    time_nanoseconds = 0;
#endif

    int split = 0;
    uint32_t pos_in_query = 0, pos_in_ref = 0;
    while(pos_in_query < query_len){


        /*
        printf("ALOHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA------------------------ remove thisssssssssssssssssssssssssssssssssssssssssss\n");
        // This would not be here, just testing
        ret = cudaMalloc(&data_mem, effective_global_ram * sizeof(char)); 
        if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pool memory in device. Error: %d\n", ret); exit(-1); }
        */

        address_checker = 0;

        // Allocate memory in device for sequence chunk
        // We have to this here since later on we will have to free all memory to load the hits
        //ret = cudaMalloc(&seq_dev_mem, words_at_once * sizeof(char));
        //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for query sequence in device (Attempted %" PRIu32" bytes). Error: %d\n", (uint32_t) (words_at_once * sizeof(char)), ret); exit(-1); }

        // Allocate words table
        //ret = cudaMalloc(&keys, words_at_once * sizeof(uint64_t));
        //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for table in device (1). Error: %d\n", ret); exit(-1); }
        //ret = cudaMalloc(&values, words_at_once * sizeof(uint32_t));
        //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for table in device (2). Error: %d\n", ret); exit(-1); }
#ifdef SHOWTIME
        clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif
        // ## POINTER SECTION 1
        char * ptr_seq_dev_mem = &data_mem[0];
        char * base_ptr = ptr_seq_dev_mem;
        address_checker = realign_address(address_checker + words_at_once, 8);
        
        uint64_t * ptr_keys = (uint64_t *) (base_ptr + address_checker); // We have to realign because of the arbitrary length of the sequence chars
        address_checker = realign_address(address_checker + words_at_once * sizeof(uint64_t), 4);

        uint32_t * ptr_values = (uint32_t *) (base_ptr + address_checker); 
        address_checker = realign_address(address_checker + words_at_once * sizeof(uint32_t), 8);
        

        fprintf(stdout, "[EXECUTING] Running split %d -> (%d%%)[%u,%u]\n", split, (int)((100*(uint64_t)pos_in_query)/(uint64_t)query_len), pos_in_query, pos_in_ref);

        uint32_t items_read_x = MIN(query_len - pos_in_query, words_at_once);


        ////////////////////////////////////////////////////////////////////////////////
        // Run kmers for query
        ////////////////////////////////////////////////////////////////////////////////
        
        // Load sequence chunk into ram 
        ret = cudaMemcpy(ptr_seq_dev_mem, &query_seq_host[pos_in_query], items_read_x, cudaMemcpyHostToDevice);
        if(ret != cudaSuccess){ fprintf(stderr, "Could not copy query sequence to device. Error: %d\n", ret); exit(-1); }

        // Initialize space
        ret = cudaMemset(ptr_keys, 0xFFFFFFFF, words_at_once * sizeof(uint64_t));
        ret = cudaMemset(ptr_values, 0xFFFFFFFF, words_at_once * sizeof(uint32_t));
        ret = cudaDeviceSynchronize();
        
        
        number_of_blocks = (items_read_x - KMER_SIZE + 1)/(64) + 1;


        if(number_of_blocks != 0)
        {
            kernel_index_global32<<<number_of_blocks, 64>>>(ptr_keys, ptr_values, ptr_seq_dev_mem, pos_in_query, items_read_x);
        
            ret = cudaDeviceSynchronize();
            if(ret != cudaSuccess){ fprintf(stderr, "Could not compute kmers on query. Error: %d\n", ret); exit(-1); }
        }
        else
        {
            fprintf(stdout, "[WARNING] Zero blocks for query words\n");
        }

        // FOR DEBUG
        // Copy kmers to local
        
        /*
        uint64_t * kmers = (uint64_t *) malloc(words_at_once * sizeof(uint64_t));
        uint64_t * poses = (uint64_t *) malloc(words_at_once * sizeof(uint64_t));
        ret = cudaMemcpy(kmers, keys, items_read_x*sizeof(uint64_t), cudaMemcpyDeviceToHost);
        ret = cudaMemcpy(poses, values, items_read_x*sizeof(uint64_t), cudaMemcpyDeviceToHost);
        FILE * anything8 = fopen("kmers", "a");
        for(i=0; i<words_at_once; i++){
            fprintf(anything8, "%" PRIu64" %" PRIu64" %" PRIu64"\n", i, poses[i], kmers[i]);
        }
        free(kmers); free(poses);
        fclose(anything8);
        */
#ifdef SHOWTIME
        clock_gettime(CLOCK_MONOTONIC, &HD_end);
        time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
        time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
        time_seconds *= BILLION;
        fprintf(stdout, "[INFO] words Q t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
        time_seconds = 0;
        time_nanoseconds = 0;
#endif

        ////////////////////////////////////////////////////////////////////////////////
        // Sort the query kmers
        ////////////////////////////////////////////////////////////////////////////////

        // Notice --------- Now that we are usiung pooled memory
        // I have not "freed" the part corresponding to the sequence (ptr_seq_dev_mem)
        // ANd thus next points build upon that
        // But thats no problem because it is a small fraction of memory

        //ret = cudaMalloc(&keys_buf, words_at_once * sizeof(uint64_t));
        //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for table in device (3). Error: %d\n", ret); exit(-1); }
        //ret = cudaMalloc(&values_buf, words_at_once * sizeof(uint32_t));
        //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for table in device (4). Error: %d\n", ret); exit(-1); }


        // ## POINTER SECTION 2
#ifdef SHOWTIME
        clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif        
        


        mergesort(ptr_keys, ptr_values, items_read_x, mgpu::less_t<uint64_t>(), context);
        ret = cudaDeviceSynchronize();
        if(ret != cudaSuccess){ fprintf(stderr, "MERGESORT sorting failed on query. Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }
        

        // Download sorted kmers [ No need to download because of hits processing ###]
        //ret = cudaMemcpyAsync(dict_x_keys, ptr_keys, items_read_x*sizeof(uint64_t), cudaMemcpyDeviceToHost, streams[0]);
        //if(ret != cudaSuccess){ fprintf(stderr, "Downloading device kmers (1). Error: %d\n", ret); exit(-1); }
        //ret = cudaMemcpyAsync(dict_x_values, ptr_values, items_read_x*sizeof(uint32_t), cudaMemcpyDeviceToHost, streams[1]);
        //if(ret != cudaSuccess){ fprintf(stderr, "Downloading device kmers (2). Error: %d\n", ret); exit(-1); }

        // Print hits for debug
        //for(i=0; i<items_read_x; i++){
        //    fprintf(out, "%" PRIu64"\n", dict_x_values[i]);
        //}

        
#ifdef SHOWTIME
        clock_gettime(CLOCK_MONOTONIC, &HD_end);
        time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
        time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );

        time_seconds *= BILLION;
        fprintf(stdout, "[INFO] sortwords Q t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
        time_seconds = 0;
        time_nanoseconds = 0;
#endif 

        pos_in_query += words_at_once;

        //cudaFree(keys);
        //cudaFree(values)
        //cudaFree(keys_buf);
        //cudaFree(values_buf);

        ////////////////////////////////////////////////////////////////////////////////
        // Run the reference blocks
        ////////////////////////////////////////////////////////////////////////////////

        /*
        printf("ALOHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA------------------------ remove thisssssssssssssssssssssssssssssssssssssssssss\n");
        cudaFree(data_mem);

        printf("ALOHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA------------------------ remove thisssssssssssssssssssssssssssssssssssssssssss\n");
        // This would not be here, just testing
        ret = cudaMalloc(&data_mem, effective_global_ram * sizeof(char)); 
        if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate pool memory in device. Error: %d\n", ret); exit(-1); }
        */

        // These definitions are for the processing of hits - reused in reference and query
        uint64_t * ptr_device_diagonals;
        int32_t * ptr_device_error;
        uint32_t * ptr_hits_log, * ptr_hits_log_extra;
        uint64_t * ptr_keys_2;
        uint32_t * ptr_values_2;

        while(pos_in_ref < ref_len){

            ////////////////////////////////////////////////////////////////////////////////
            // FORWARD strand in the reference
            ////////////////////////////////////////////////////////////////////////////////
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif
            uint32_t items_read_y = MIN(ref_len - pos_in_ref, words_at_once);

            //ret = cudaMalloc(&seq_dev_mem, words_at_once * sizeof(char));

            // Allocate words table
            //ret = cudaMalloc(&keys, words_at_once * sizeof(uint64_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for table in device (1). Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&values, words_at_once * sizeof(uint32_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for table in device (2). Error: %d\n", ret); exit(-1); }

            // ## POINTER SECTION 3
            ptr_seq_dev_mem = &data_mem[0];
            //base_ptr = ptr_seq_dev_mem; // Currently set at the previous realignment in the query word generation
            //address_checker = realign_address(words_at_once, 8); // Currently set at the previous realignment in the query word generation

            //address_checker = realign_address(address_checker + words_at_once, 8);
            ptr_keys_2 = (uint64_t *) (base_ptr + address_checker); // We have to realign because of the arbitrary length of the sequence chars
            address_checker = realign_address(address_checker + words_at_once * sizeof(uint64_t), 4);

            ptr_values_2 = (uint32_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + words_at_once * sizeof(uint32_t), 8);
            

            // Load sequence chunk into ram
            ret = cudaMemcpy(ptr_seq_dev_mem, &ref_seq_host[pos_in_ref], items_read_y, cudaMemcpyHostToDevice);
            if(ret != cudaSuccess){ fprintf(stderr, "Could not copy ref sequence to device. Error: %d\n", ret); exit(-1); }

            // Run kmers
            ret = cudaMemset(ptr_keys_2, 0xFFFFFFFF, words_at_once * sizeof(uint64_t));
            ret = cudaMemset(ptr_values_2, 0xFFFFFFFF, words_at_once * sizeof(uint32_t));
            ret = cudaDeviceSynchronize();
            
            
            number_of_blocks = ((items_read_y - KMER_SIZE + 1))/(64) + 1;
            if(number_of_blocks != 0)
            {

                kernel_index_global32<<<number_of_blocks, 64>>>(ptr_keys_2, ptr_values_2, ptr_seq_dev_mem, pos_in_ref, items_read_y);
                ret = cudaDeviceSynchronize();
                if(ret != cudaSuccess){ fprintf(stderr, "Could not compute kmers on ref. Error: %d\n", ret); exit(-1); }

            }
            else
            {
                fprintf(stdout, "[WARNING] Zero blocks for ref words\n");
            }
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] words R t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
#endif 

            


            //cudaFree(seq_dev_mem);

            

            ////////////////////////////////////////////////////////////////////////////////
            // Sort reference FORWARD kmers
            ////////////////////////////////////////////////////////////////////////////////

            //ret = cudaMalloc(&keys_buf, words_at_once * sizeof(uint64_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for table in device (3). Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&values_buf, words_at_once * sizeof(uint32_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for table in device (4). Error: %d\n", ret); exit(-1); }

            // ## POINTER SECTION 4
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif
        
            //address_checker = realign_address(address_checker, 8);
            //ptr_keys_buf = (uint64_t *) (base_ptr + address_checker);
            //address_checker = realign_address(address_checker + words_at_once * sizeof(uint64_t), 4);

            //ptr_values_buf = (uint32_t *) (base_ptr + address_checker); // Each alloc adds on top of the previous one
            //address_checker = realign_address(address_checker + words_at_once * sizeof(uint32_t), 4);

            //ret = cudaMemset(ptr_keys_buf, 0xFFFFFFFF, words_at_once * sizeof(uint64_t));
            //ret = cudaMemset(ptr_values_buf, 0xFFFFFFFF, words_at_once * sizeof(uint32_t));

            //cub::DoubleBuffer<uint64_t> d_keys_ref(ptr_keys, ptr_keys_buf);
            //cub::DoubleBuffer<uint32_t> d_values_ref(ptr_values, ptr_values_buf);

            //d_temp_storage = NULL;
            //temp_storage_bytes = 0;

            //cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes, d_keys_ref, d_values_ref, items_read_y);
            //ret = cudaDeviceSynchronize();
            //if(ret != cudaSuccess){ fprintf(stderr, "Bad pre-sorting (2). Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }

            // Allocate temporary storage
            //ret = cudaMalloc(&d_temp_storage, temp_storage_bytes);
            //if(ret != cudaSuccess){ fprintf(stderr, "Bad allocating of temp storage for words sorting (2). Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }
            
            //cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes, d_keys_ref, d_values_ref, items_read_y);
            //ret = cudaDeviceSynchronize();
            //if(ret != cudaSuccess){ fprintf(stderr, "CUB sorting failed on ref. Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }
            
            mergesort(ptr_keys_2, ptr_values_2, items_read_y, mgpu::less_t<uint64_t>(), context);

            ret = cudaDeviceSynchronize();
            if(ret != cudaSuccess){ fprintf(stderr, "MODERNGPU sorting failed on ref words. Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }



            // Download sorted reference kmers [ No download of kmers because of hits processing in gpu ]
            //ret = cudaMemcpy(dict_y_keys, ptr_keys, items_read_y*sizeof(uint64_t), cudaMemcpyDeviceToHost);
            //if(ret != cudaSuccess){ fprintf(stderr, "Downloading device kmers (3). Error: %d\n", ret); exit(-1); }
            //ret = cudaMemcpy(dict_y_values, ptr_values, items_read_y*sizeof(uint32_t), cudaMemcpyDeviceToHost);
            //if(ret != cudaSuccess){ fprintf(stderr, "Downloading device kmers (4). Error: %d\n", ret); exit(-1); }

            pos_in_ref += words_at_once;
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] sortwords R t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
#endif 


            ////////////////////////////////////////////////////////////////////////////////
            // Generate FORWARD hits for the current split
            ////////////////////////////////////////////////////////////////////////////////

            
            //read_kmers(query_len, query_seq_host, dict_x_keys, dict_x_values);
            //Qsort(dict_x_keys, dict_x_values, 0, (int64_t) query_len);
            //for(i=0; i<words_at_once; i++) printf("%"  PRIu64" %" PRIu64"\n", dict_x_keys[i], dict_x_values[i]);
            //read_kmers(ref_len, ref_seq_host, dict_y_keys, dict_y_values);
            //Qsort(dict_y_keys, dict_y_values, 0, (int64_t) ref_len);
            //for(i=0; i<words_at_once; i++) printf("%"  PRIu64" %" PRIu64"\n", dict_y_keys[i], dict_y_values[i]);

            /*
            uint64_t * keysX1 = (uint64_t *) dump_memory_region((char *)ptr_keys, words_at_once * sizeof(uint64_t));
            uint64_t * keysX2 = (uint64_t *) dump_memory_region((char *)ptr_keys_2, words_at_once * sizeof(uint64_t));
            uint32_t * valuesX1 = (uint32_t *) dump_memory_region((char *)ptr_values, words_at_once * sizeof(uint32_t));
            uint32_t * valuesX2 = (uint32_t *) dump_memory_region((char *)ptr_values_2, words_at_once * sizeof(uint32_t));
            for(i=0; i<words_at_once; i++) fprintf(stdout, "thisKeysXForDebug %" PRIu64" %" PRIu64" -> (%" PRIu32", %" PRIu32" )\n", keysX1[i], keysX2[i], valuesX1[i], valuesX2[i]);
            */
            
            //cudaFree(keys);
            //cudaFree(values);
            //cudaFree(keys_buf);
            //cudaFree(values_buf);
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif

            uint32_t n_hits_found = 0;
            if(fast == 2)
                n_hits_found = generate_hits_fast(max_hits, diagonals, hits, dict_x_keys, dict_y_keys, dict_x_values, dict_y_values, items_read_x, items_read_y, query_len, ref_len);     

//#ifdef AVX512CUSTOM
//                n_hits_found = generate_hits_sensitive_avx512(max_hits, diagonals, hits, dict_x_keys, dict_y_keys, dict_x_values, dict_y_values, items_read_x, items_read_y, query_len, ref_len);
//#else
//                n_hits_found = generate_hits_sensitive(max_hits, diagonals, hits, dict_x_keys, dict_y_keys, dict_x_values, dict_y_values, items_read_x, items_read_y, query_len, ref_len, max_frequency, fast);
//#endif
            uint32_t n_blocks_hits = 8192;//items_read_x / 128;

            // Save memory for hits
            //address_checker = 0;
            //base_ptr = &data_mem[0]; // Keep building on top of what we have
            

            ptr_device_error = (int32_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + sizeof(int32_t), 4);

            ptr_hits_log = (uint32_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + sizeof(uint32_t) * n_blocks_hits, 4);

            // Set error status to one
            ret = cudaMemset(ptr_device_error, 0x00000000, sizeof(int32_t));
            ret = cudaDeviceSynchronize();
            
            /////////////////// DEBUG MESSAGES INFO
            /*
            uint32_t message_sizes = 1000*1000*10;
            address_checker = realign_address(address_checker + sizeof(uint32_t) * n_blocks_hits, 8);
            uint64_t * ptr_messages_log = (uint64_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + sizeof(uint64_t) * message_sizes, 4);
            cudaMemset(ptr_messages_log, 0x00000000, sizeof(uint64_t) * message_sizes);
            */
            //////////////////// END 

            uint64_t hits_in_first_mem_block = max_hits / 4;
            uint64_t hits_in_second_mem_block = max_hits + 3 * (max_hits/4) - 1000*1000; // SOme has to be removed due to all allocated variables on pool (besides words and seq) TODO: allocate them at the beginning
            uint64_t mem_block = (hits_in_first_mem_block)/n_blocks_hits;
            uint64_t max_extra_sections = n_blocks_hits * 0.1;
            uint64_t extra_large_mem_block = (hits_in_second_mem_block)/max_extra_sections;

            ptr_hits_log_extra = (uint32_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + sizeof(uint32_t) * max_extra_sections, 4);
            
            fprintf(stdout, "-----DEBUG \n\tsize of mem block ==:> %" PRIu64 " (%" PRIu64" hits)\n\tsize of extra mem block ===:> %" PRIu64"(%" PRIu64" hits)\n\tsections ===:>%" PRIu64"\n", mem_block * sizeof(uint64_t), mem_block, extra_large_mem_block * sizeof(uint64_t), extra_large_mem_block, max_extra_sections);

            uint32_t * ptr_leftmost_key_x = (uint32_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + sizeof(uint32_t), 4);
            uint32_t * ptr_leftmost_key_y = (uint32_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + sizeof(uint32_t), 4);
            int32_t * ptr_atomic_distributer = (int32_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + sizeof(int32_t), 4);
            ret = cudaMemset(ptr_atomic_distributer, 0x00000000, sizeof(int32_t));
            ret = cudaDeviceSynchronize();


            kernel_find_leftmost_items<<<1, 1>>>(ptr_keys, ptr_leftmost_key_x, ptr_keys_2, ptr_leftmost_key_y, items_read_x, items_read_y);
            ret = cudaDeviceSynchronize();
            uint32_t leftmost_key_x, leftmost_key_y;
            if(ret != cudaSuccess){ fprintf(stderr, "Error searching true leftmost elements on device. Error: %d\n", ret); exit(-1); }
            ret = cudaMemcpy(&leftmost_key_x, ptr_leftmost_key_x, sizeof(uint32_t), cudaMemcpyDeviceToHost);
            if(ret != cudaSuccess){ fprintf(stderr, "Downloading leftmost element X. Error: %d\n", ret); exit(-1); }
            ret = cudaMemcpy(&leftmost_key_y, ptr_leftmost_key_y, sizeof(uint32_t), cudaMemcpyDeviceToHost);
            if(ret != cudaSuccess){ fprintf(stderr, "Downloading leftmost element Y. Error: %d\n", ret); exit(-1); }

            printf("Leftmost elements are: %u, %u out of [%u, %u]\n", leftmost_key_x, leftmost_key_y, items_read_x, items_read_y);

            address_checker = realign_address(address_checker, 8);
            ptr_device_diagonals = (uint64_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + hits_in_first_mem_block * sizeof(uint64_t), 8);

            uint64_t * ptr_auxiliary_hit_memory = (uint64_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + hits_in_second_mem_block * sizeof(uint64_t), 8);
            //cudaProfilerStart();

            ret = cudaMemset(ptr_device_diagonals, 0xFFFFFFFF, sizeof(uint64_t)*hits_in_first_mem_block);
            ret = cudaDeviceSynchronize();
            if(ret != cudaSuccess){ fprintf(stderr, "Setting to 0xFF..FF the device diagonals. Error: %d\n", ret); exit(-1); }
            
            ret = cudaMemset(ptr_auxiliary_hit_memory, 0xFFFFFFFF, sizeof(uint64_t)*hits_in_second_mem_block);
            ret = cudaDeviceSynchronize();
            if(ret != cudaSuccess){ fprintf(stderr, "Setting to 0xFF..FF the extra device diagonals. Error: %d\n", ret); exit(-1); }
            

            kernel_hits<<<n_blocks_hits, 32>>>(ptr_keys, ptr_keys_2, ptr_values, ptr_values_2, ptr_device_diagonals, (int32_t) mem_block, 
                leftmost_key_x, leftmost_key_y, ptr_device_error, ref_len, ptr_hits_log, ptr_atomic_distributer, ptr_auxiliary_hit_memory,
                 (uint32_t) extra_large_mem_block, (uint32_t) max_extra_sections, ptr_hits_log_extra);//, ptr_messages_log);

            //cudaProfilerStop();
            ret = cudaDeviceSynchronize();

            if(ret != cudaSuccess){ fprintf(stderr, "Fatal error generating hits on device. Error: %d\n", ret); exit(-1); }
            int32_t device_error;
            ret = cudaMemcpy(&device_error, ptr_device_error, sizeof(int32_t), cudaMemcpyDeviceToHost);
            int32_t reached_sections = -1;
            ret = cudaMemcpy(&reached_sections, ptr_atomic_distributer, sizeof(int32_t), cudaMemcpyDeviceToHost);
            if(ret != cudaSuccess){ fprintf(stderr, "Downloading error status on hits generation. Error: %d\n", ret); exit(-1); }
            printf("debug from error hits : %d [reached: %d]\n", device_error, reached_sections);
            if(device_error < 0) { fprintf(stderr, "Error generating hits on device. Error: %d\n", device_error);  }

            // ADD kernel here to copy hits consecutively
            //pre_alloc // this is the char * pointer for auxiliary memory in the sorts

            ////////////////////////////////////////////////////////////////////////////////
            // Hits compacting
            ////////////////////////////////////////////////////////////////////////////////

            uint32_t * hits_log = (uint32_t *) malloc(n_blocks_hits*sizeof(uint32_t)); 
            uint32_t * extra_log = (uint32_t *) malloc(max_extra_sections*sizeof(uint32_t)); 
            uint32_t * accum_log = (uint32_t *) malloc(n_blocks_hits*sizeof(uint32_t)); 
            
            ret = cudaMemcpy(hits_log, ptr_hits_log, sizeof(uint32_t)*n_blocks_hits, cudaMemcpyDeviceToHost);
            ret = cudaMemcpy(extra_log, ptr_hits_log_extra, sizeof(uint32_t)*max_extra_sections, cudaMemcpyDeviceToHost);
            for(i=0; i<n_blocks_hits; i++) {
                accum_log[i] = n_hits_found;
                n_hits_found += hits_log[i];
                //printf("acum log previous %u -> %u\n", i, accum_log[i]);
                printf("LOGGO block %u has %u hits while max is %" PRIu64"\n", i, hits_log[i], mem_block); 
            }

            
            uint64_t * download_hits_DEBUG = (uint64_t *) dump_memory_region((char *)ptr_device_diagonals, hits_in_first_mem_block * sizeof(uint64_t));
            for(i=0; i<hits_in_first_mem_block; i++){
                //if(download_hits_DEBUG[i] != 0xFFFFFFFFFFFFFFFF)
                printf("[goodhit] %" PRIu64"\n", download_hits_DEBUG[i]);
            }
            
            

            // First step: measure how many hits can be stored at once (in the worst case) in the words section
            // This is (consecutive region): ptr_keys,ptr_values,ptr_keys_2,ptr_values_2
            // And amounts for: words_at_once * (8+4+8+4) bytes
            // which equals max number of 8-byte diagonals: 3*words_at_once

            uint64_t * ptr_copy_place_diagonals = (uint64_t *) &ptr_keys[0];
            uint32_t max_copy_diagonals = 3 * (uint32_t) words_at_once;
            uint32_t blocks_per_section = mem_block / 512 + 1;
            uint32_t runs = (uint32_t) hits_in_first_mem_block / max_copy_diagonals + 1;

            // Upload accumulated (overwrite sequence data since its no longer needed)
            uint32_t * ptr_accum_log = (uint32_t *) (&data_mem[0]);
            ret = cudaMemcpy(ptr_accum_log, accum_log, sizeof(uint32_t)*n_blocks_hits, cudaMemcpyHostToDevice);

            printf("There will be %u runs on first part. [total blocks: %u, total threads: %u]\n", runs, n_blocks_hits * blocks_per_section, n_blocks_hits / blocks_per_section);

            kernel_compact_hits<<<n_blocks_hits * blocks_per_section, 512>>>(ptr_device_diagonals, ptr_hits_log, ptr_accum_log, blocks_per_section, mem_block, ptr_copy_place_diagonals, 0);
            ret = cudaDeviceSynchronize();

            if(ret != cudaSuccess){ fprintf(stderr, "Could not compact hits on first stage. Error: %d\n", ret); exit(-1); }

            ret = cudaMemcpy(ptr_device_diagonals, ptr_copy_place_diagonals, sizeof(uint64_t)*n_hits_found, cudaMemcpyDeviceToDevice);

            uint32_t total_hits_copied = n_hits_found;
            // Second run
            uint32_t second_hits_found = 0;

            for(i=0; i<max_extra_sections; i++) {
                accum_log[i] = second_hits_found;
                second_hits_found += extra_log[i];
                //printf("accum log %u -> %u\n", i, accum_log[i]);
                //printf("LOGGO EXTRA! block %u has %u hits while max is %" PRIu64"\n", i, extra_log[i], extra_large_mem_block); 
            }

            ret = cudaMemcpy(ptr_accum_log, accum_log, sizeof(uint32_t)*max_extra_sections, cudaMemcpyHostToDevice);

            runs = (uint32_t) hits_in_second_mem_block / max_copy_diagonals + 1;
            printf("There will be %u runs on second part\n", runs);
            blocks_per_section = extra_large_mem_block / 512;
            uint32_t sections_per_run = (max_extra_sections / runs);
            
            

            for(i=0; i<runs && reached_sections>0; i++){

                
                uint32_t section_from = sections_per_run * i;
                uint32_t offset_remover = accum_log[section_from];
                printf("Run %u - > starting from section %u ||| removing offset %u\n", i, section_from, offset_remover);
                kernel_compact_hits<<<sections_per_run * blocks_per_section, 512>>>(&ptr_auxiliary_hit_memory[section_from], &ptr_hits_log_extra[section_from], ptr_accum_log, blocks_per_section, extra_large_mem_block, ptr_copy_place_diagonals, offset_remover);
                ret = cudaDeviceSynchronize();
                if(ret != cudaSuccess){ fprintf(stderr, "Could not compact hits on second stage run %u. Error: %d\n", i, ret); exit(-1); }

                ret = cudaMemcpy(&ptr_device_diagonals[total_hits_copied], ptr_copy_place_diagonals, sizeof(uint64_t)*accum_log[sections_per_run * (i+1)], cudaMemcpyDeviceToDevice);
                ret = cudaDeviceSynchronize();
                if(ret != cudaSuccess){ fprintf(stderr, "Could not memcpy the compacted hits on second stage run %u. Error: %d\n", i, ret); exit(-1); }
                total_hits_copied += accum_log[sections_per_run * (i+1)];
            }

            // Add together total number of hits
            n_hits_found += second_hits_found;


            
            uint64_t * compacted_hits = (uint64_t *) dump_memory_region((char *)ptr_device_diagonals, n_hits_found * sizeof(uint64_t));
            for(i=0; i<n_hits_found; i++){
                printf("[showinghit] %" PRIu64"\n", compacted_hits[i]);
            }
            




            /*
            uint32_t * ptr_diff_log = &ptr_values[0];

            ret = cudaMemcpy(ptr_diff_log, diff_log, n_blocks_hits * sizeof(uint32_t), cudaMemcpyHostToDevice);
            kernel_compact_hits<<<compacting_blocks, 256>>>(ptr_device_diagonals, ptr_hits_log, ptr_accum_log, ptr_aux_space, mem_block);

            //kernel_compact_hits<<<max_extra_sections,>>>(ptr_auxiliary_hit_memory, ptr_hits_log_extra, );
            */
            free(hits_log);
            free(extra_log);
            free(accum_log);

            //////////////////// DEBUG MESSAGES INFO PART 2
            /*
            uint64_t * messages_log = (uint64_t *) dump_memory_region((char *)ptr_messages_log, message_sizes * sizeof(uint64_t));
            uint32_t coord_tracker_x = 0, coord_tracker_current_x = 0, coord_tracker_y = 0, coord_tracker_current_y = 0;
            printf("\t[CoordsLog] X:%u\t Y:%u\t cY:%u\n", coord_tracker_x, coord_tracker_y=coord_tracker_current_y, coord_tracker_current_y);
            for(i=0; i<message_sizes; i++){
                uint32_t msg_id = (uint32_t) (messages_log[i] >> 32);
                uint32_t msg_ct = (uint32_t) (messages_log[i] & 0x00000000FFFFFFFF);
                printf("Message number %d with id %d:\n", i, msg_id);
                switch(msg_id){
                    case 0: { printf("\t[CoordsLog] X:%u\t Y:%u\t cX:%u\t cY:%u\t", coord_tracker_x, coord_tracker_y=coord_tracker_current_y, coord_tracker_current_x, coord_tracker_current_y); printf("\tMinor Strong y increment %d!\n", msg_ct); }
                    break;
                    case 1: { printf("\t[CoordsLog] X:%u\t Y:%u\t cX:%u\t cY:%u\t", coord_tracker_x, coord_tracker_y, ++coord_tracker_current_x, coord_tracker_current_y=coord_tracker_y); printf("\tAdvance x %d!\n", msg_ct);}
                    break;
                    case 2: { printf("\t[CoordsLog] X:%u\t Y:%u\t cX:%u\t cY:%u\t", coord_tracker_x, coord_tracker_y, coord_tracker_current_x, coord_tracker_current_y+=32); printf("\tBasic y increment %d!\n", msg_ct);}
                    break;
                    case 3: { coord_tracker_x+=32; printf("\t[CoordsLog] X:%u\t Y:%u\t cX:%u\t cY:%u\t", coord_tracker_x, coord_tracker_y=coord_tracker_current_y, coord_tracker_current_x=coord_tracker_x, coord_tracker_current_y=coord_tracker_y); printf("\tFetched next x block %d!\n", msg_ct);} 
                    break;
                    case 4: {  printf("\t[CoordsLog] X:%u\t Y:%u\t cX:%u\t cY:%u\t", coord_tracker_x, coord_tracker_y=coord_tracker_current_y, coord_tracker_current_x, coord_tracker_current_y); printf("\tMajor Strong y increment %d!\n", msg_ct); }
                    break;
                }
                if(i > 0 && msg_ct == 0x00000000 && msg_id == 0x00000000) break;
            }
            */
            

            //////////////////// END 2

            // Download data
            /*
            uint64_t * keysX1 = (uint64_t *) dump_memory_region((char *)ptr_keys, words_at_once * sizeof(uint64_t));
            uint64_t * keysX2 = (uint64_t *) dump_memory_region((char *)ptr_keys_2, words_at_once * sizeof(uint64_t));
            uint32_t * valuesX1 = (uint32_t *) dump_memory_region((char *)ptr_values, words_at_once * sizeof(uint32_t));
            uint32_t * valuesX2 = (uint32_t *) dump_memory_region((char *)ptr_values_2, words_at_once * sizeof(uint32_t));
            for(i=0; i<max(items_read_x, items_read_y); i++){ if(valuesX1[i] == 0xFFFFFFFF || valuesX2[i] == 0xFFFFFFFF) break; fprintf(stdout, "thisKeysXForDebug %" PRIu64" %" PRIu64" -> (%" PRIu32", %" PRIu32" ) compare: %d\n", keysX1[i], keysX2[i], valuesX1[i], valuesX2[i], (keysX1[i] < keysX2[i]) ? (-1) : ((keysX1[i] == keysX2[i])? (0): (1))  ); }
            */
            //uint64_t * get_my_hits = (uint64_t *) dump_memory_region((char *)ptr_device_diagonals, n_hits_found * sizeof(uint64_t));
            //for(i=0; i<n_hits_found; i++) fprintf(stdout, "thisHitForDebug %" PRIu64", %" PRIu64", %" PRIu64"\n", get_my_hits[i], get_my_hits[i], get_my_hits[i]);
            
            

#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] hits Q-R t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
            fprintf(stdout, "[INFO] Generated %" PRIu32" hits on split %d -> (%d%%)[%u,%u]{%u,%u}\n", n_hits_found + second_hits_found, split, (int)((100*MIN((uint64_t)pos_in_ref, (uint64_t)ref_len))/(uint64_t)ref_len), pos_in_query, pos_in_ref, items_read_x, items_read_y);
#endif 
            


            // Print hits for debug
            //for(i=0; i<n_hits_found; i++){
            //    fprintf(stdout, "thisHitForDebug %" PRIu64"\n", diagonals[i]);
            //}
            //for(i=0; i<n_hits_found; i++){
                //printf("%" PRIu64"\n", diagonals[i]);
                //if(hits[i].p1 > 368000 && hits[i].p2 < 390000)
                    //fprintf(out, "Frag,d:%"PRId64",%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64",f,0,32,32,32,1.0,1.0,0,0\n", (int64_t) hits[i].p1 - (int64_t) hits[i].p2, hits[i].p1, hits[i].p2, hits[i].p1+32, hits[i].p2+32);
            //}

            ////////////////////////////////////////////////////////////////////////////////
            // Sort hits for the current split
            ////////////////////////////////////////////////////////////////////////////////

            //ret = cudaMalloc(&device_diagonals, max_hits * sizeof(uint64_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for hits in device (1). Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&device_diagonals_buf, max_hits * sizeof(uint64_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for hits in device (2). Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&device_hits, max_hits * sizeof(uint32_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for hits in device (3). Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&device_hits_buf, max_hits * sizeof(uint32_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for hits in device (4). Error: %d\n", ret); exit(-1); }



            // ## POINTER SECTION 5
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif
            //address_checker = 0;
            //base_ptr = &data_mem[0];
            //address_checker = realign_address(address_checker, 8);
            //uint64_t * ptr_device_diagonals = (uint64_t *) (base_ptr + address_checker);
            //address_checker = realign_address(address_checker + max_hits * sizeof(uint64_t), 4);

            // [ No need to recopy because of hits processing ]
            //ret = cudaMemcpy(ptr_device_diagonals, diagonals, n_hits_found*sizeof(uint64_t), cudaMemcpyHostToDevice);
            //if(ret != cudaSuccess){ fprintf(stderr, "Uploading device diagonals. Error: %d\n", ret); exit(-1); }

            //ret = cudaMemset(pre_alloc, 0x00000000, max_hits * sizeof(uint64_t));


            // CURRENTLY FAILING HERE BECAUSE THE SIZE OF ptr_device_diagonals AND n_hits_found DOES NOT ADD UP
            mergesort(ptr_device_diagonals, n_hits_found, mgpu::less_t<uint64_t>(), context);

            ret = cudaDeviceSynchronize();
            if(ret != cudaSuccess){ fprintf(stderr, "MODERNGPU sorting failed on query-ref hits. Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }

#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] sorthits Q-R t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
#endif 

            memset(filtered_hits_x, 0x0000, n_hits_found * sizeof(uint32_t));
            memset(filtered_hits_y, 0x0000, n_hits_found * sizeof(uint32_t));
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif
            //kernel_filter_hits<<<n_hits_found/(32*32)+1, 32>>>(ptr_device_diagonals, ref_len, n_hits_found);
            //cudaProfilerStart();


            // I KNOW WHY LESS HITS/FRAGS ARE BEING GENERATED:
            // THE FILTERING IS BEING APPLIED TO THE N_HITS_FOUND REGION, BUT THE HITS ARE WRITTEN SCATTERED IN BLOCKS IN THE PARALLEL KERNEL

            kernel_filter_hits_parallel<<<n_hits_found/(64)+1, 64>>>(ptr_device_diagonals, ref_len, n_hits_found);
            ret = cudaDeviceSynchronize();
            //cudaProfilerStop();
            if(ret != cudaSuccess){ fprintf(stderr, "FILTER HITS failed on query-ref hits. Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }

            ret = cudaMemcpy(diagonals, ptr_device_diagonals, n_hits_found*sizeof(uint64_t), cudaMemcpyDeviceToHost);
            if(ret != cudaSuccess){ fprintf(stderr, "Downloading device diagonals. Error: %d\n", ret); exit(-1); }


            uint32_t n_hits_kept = filter_hits_cpu(diagonals, filtered_hits_x, filtered_hits_y, n_hits_found);
            
            //uint32_t n_hits_kept = filter_hits_forward(diagonals, indexing_numbers, hits, filtered_hits_x, filtered_hits_y, n_hits_found);

#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] filterhits Q-R t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
            fprintf(stdout, "[INFO] Remaining hits %" PRIu32"\n", n_hits_kept);
#endif
            
            //for(i=0; i<n_hits_kept; i++){
            //    printf("GET THIS HIT %" PRIu64"\n", diagonals[i]);
            //    //fprintf(stdout, "Frag,%" PRIu32",%" PRIu32",%" PRIu32",%" PRIu32",f,0,32,32,32,1.0,1.0,0,0\n", filtered_hits_x[i], filtered_hits_y[i], filtered_hits_x[i]+32, filtered_hits_y[i]+32);
            //}
            //ret = cudaFree(d_temp_storage);
            //ret = cudaFree(device_hits);
            //ret = cudaFree(device_diagonals);
            //ret = cudaFree(device_diagonals_buf);
            //ret = cudaFree(device_hits_buf);

            

            ////////////////////////////////////////////////////////////////////////////////
            // Generate FORWARD frags
            ////////////////////////////////////////////////////////////////////////////////

            // Allocate both sequences
            //ret = cudaMalloc(&seq_dev_mem, words_at_once * sizeof(char)); if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate for query sequence in device. Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&seq_dev_mem_aux, words_at_once * sizeof(char)); if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate for ref sequence in device. Error: %d\n", ret); exit(-1); }

            //ret = cudaMalloc(&device_filt_hits_x, max_hits * sizeof(uint32_t)); if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate for device filtered hits query. Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&device_filt_hits_y, max_hits * sizeof(uint32_t)); if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate for device filtered hits ref. Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&left_offset, max_hits * sizeof(uint32_t)); if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate for device offset left frags query. Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&right_offset, max_hits * sizeof(uint32_t)); if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate for device offset right frags query. Error: %d\n", ret); exit(-1); }


            // ## POINTER SECTION 6
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif
            address_checker = 0;
            base_ptr = &data_mem[0];
            ptr_seq_dev_mem = (char *) (base_ptr);
            address_checker = realign_address(address_checker + words_at_once, 32);

            ptr_seq_dev_mem_aux = (char *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + words_at_once, 32);


            uint32_t * ptr_device_filt_hits_x = (uint32_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + max_hits * sizeof(uint32_t), 32);

            uint32_t * ptr_device_filt_hits_y = (uint32_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + max_hits * sizeof(uint32_t), 32);

            // For half of the hits and frags we use the memory pool and for the other half we use the prealloc pool for sorting
            // Otherwise if there are too many hits they wont fit in just one pool

            uint64_t address_checker_pre_alloc = 0;
            char * base_pre_alloc_ptr = &pre_alloc[0];

            uint32_t * ptr_left_offset = (uint32_t *) (base_pre_alloc_ptr + address_checker_pre_alloc);
            address_checker_pre_alloc = realign_address(address_checker_pre_alloc + max_hits * sizeof(uint32_t), 32);

            uint32_t * ptr_right_offset = (uint32_t *) (base_pre_alloc_ptr + address_checker_pre_alloc);
            address_checker_pre_alloc = realign_address(address_checker_pre_alloc + max_hits * sizeof(uint32_t), 32);



            ret = cudaMemcpy(ptr_seq_dev_mem, &query_seq_host[pos_in_query-words_at_once], MIN(query_len - (pos_in_query - words_at_once), words_at_once), cudaMemcpyHostToDevice); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy query sequence to device for frags. Error: %d\n", ret); exit(-1); }
            ret = cudaMemcpy(ptr_seq_dev_mem_aux, &ref_seq_host[pos_in_ref-words_at_once], MIN(ref_len - (pos_in_ref - words_at_once), words_at_once), cudaMemcpyHostToDevice); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy ref sequence to device for frags. Error: %d\n", ret); exit(-1); }
            
            ret = cudaMemcpy(ptr_device_filt_hits_x, filtered_hits_x, n_hits_kept * sizeof(uint32_t), cudaMemcpyHostToDevice); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy filtered hits x in device. Error: %d\n", ret); exit(-1); }
            ret = cudaMemcpy(ptr_device_filt_hits_y, filtered_hits_y, n_hits_kept * sizeof(uint32_t), cudaMemcpyHostToDevice); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy filtered hits y in device. Error: %d\n", ret); exit(-1); }
            ret = cudaMemset(ptr_left_offset, 0x0, n_hits_kept * sizeof(uint32_t)); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy left offset in device. Error: %d\n", ret); exit(-1); }
            ret = cudaMemset(ptr_right_offset, 0x0, n_hits_kept * sizeof(uint32_t)); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy right offset in device. Error: %d\n", ret); exit(-1); }
            ret = cudaDeviceSynchronize();
            //
            //for(i=n_hits_kept-1; i>1; i--){
            //    printf(" Frag %" PRIu64" \t x: %.32s %" PRIu64"\n", i, &query_seq_host[filtered_hits_x[i]], filtered_hits_x[i]);
            //    printf(" \t\t y: %.32s %" PRIu64"\n", &ref_seq_host[filtered_hits_y[i]], filtered_hits_y[i]);
            //}

            number_of_blocks = (n_hits_kept / n_frags_per_block) + 1;




            if(number_of_blocks != 0)
            {
                kernel_frags_forward_register<<<number_of_blocks, threads_number>>>(ptr_device_filt_hits_x, ptr_device_filt_hits_y, ptr_left_offset, ptr_right_offset, ptr_seq_dev_mem, ptr_seq_dev_mem_aux, query_len, ref_len, pos_in_query-words_at_once, pos_in_ref-words_at_once, MIN(pos_in_query, query_len), MIN(pos_in_ref, ref_len), n_hits_kept, n_frags_per_block);
                //kernel_frags_forward_register<<<number_of_blocks, threads_number>>>(ptr_device_filt_hits_x, ptr_device_filt_hits_y, ptr_left_offset, ptr_right_offset, ptr_seq_dev_mem, ptr_seq_dev_mem_aux, query_len, ref_len, pos_in_query-words_at_once, pos_in_ref-words_at_once, MIN(pos_in_query, query_len), MIN(pos_in_ref, ref_len), n_hits_kept, n_frags_per_block);
                
                ret = cudaDeviceSynchronize();
                
                if(ret != cudaSuccess){ fprintf(stderr, "Failed on generating forward frags. Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }
            }

            ret = cudaMemcpy(host_left_offset, ptr_left_offset, n_hits_kept * sizeof(uint32_t), cudaMemcpyDeviceToHost); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy back left offset. Error: %d\n", ret); exit(-1); }
            ret = cudaMemcpy(host_right_offset, ptr_right_offset, n_hits_kept * sizeof(uint32_t), cudaMemcpyDeviceToHost); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy back right offset. Error: %d\n", ret); exit(-1); }

#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] frags Q-R t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
#endif 

            /*            
            char name[100] = "\0";
            sprintf(name, "onlyfrags-forward_%d", split);

            FILE * anything3 = fopen(name, "wt");
            print_header(anything3, query_len, ref_len);
            for(i=0; i<n_hits_kept; i++){
                uint64_t best_xStart = filtered_hits_x[i] - host_left_offset[i];
                uint64_t best_xEnd = filtered_hits_x[i] + host_right_offset[i];
                uint64_t best_yStart = filtered_hits_y[i] - host_left_offset[i];
                uint64_t best_yEnd = filtered_hits_y[i] + host_right_offset[i];

                int64_t d = (filtered_hits_x[i] - filtered_hits_y[i]);
                //fprintf(anything3, "hitx: %" PRIu64" hity: %" PRIu64" (d: %"PRId64") -> Frag,(%"PRId64"),%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64"\n", filtered_hits_x[i], filtered_hits_y[i], d, (int64_t)best_xStart-(int64_t)best_yStart, best_xStart, best_yStart, best_xEnd, best_yEnd, best_xEnd-best_xStart);
                //fprintf(anything3, "Frag,%"PRId64",%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64",f,0,%" PRIu64",32,32,1.0,1.0,0,0\n", d, filtered_hits_x[i], filtered_hits_y[i], best_xStart, best_yStart, best_xEnd, best_yEnd, best_xEnd-best_xStart);
                fprintf(anything3, "Frag,%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64",f,0,%" PRIu64",32,32,1.0,1.0,0,0\n", best_xStart, best_yStart, best_xEnd, best_yEnd, best_xEnd-best_xStart);
            }
            fclose(anything3);
            */
            

            //cudaFree(seq_dev_mem);
            //cudaFree(seq_dev_mem_aux);
            //cudaFree(device_filt_hits_x);
            //cudaFree(device_filt_hits_y);
            //cudaFree(left_offset);
            //cudaFree(right_offset);

#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif

            filter_and_write_frags(filtered_hits_x, filtered_hits_y, host_left_offset, host_right_offset, n_hits_kept, out, 'f', ref_len, min_length);
            //filter_and_write_frags(filtered_hits_x, filtered_hits_y, host_left_offset, host_right_offset, n_hits_kept, out, 'f', ref_len, min_length);

#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] filterFrags Q-R t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
#endif 

        }

        exit(-1);

        // Restart the reference for every block in query
        pos_in_ref = 0;

        ////////////////////////////////////////////////////////////////////////////////
        // Run the reference blocks BUT REVERSED !
        ////////////////////////////////////////////////////////////////////////////////


        while(pos_in_ref < ref_len){

            ////////////////////////////////////////////////////////////////////////////////
            // FORWARD strand in the reference BUT REVERSED !
            ////////////////////////////////////////////////////////////////////////////////

            uint32_t items_read_y = MIN(ref_len - pos_in_ref, words_at_once);

            //ret = cudaMalloc(&seq_dev_mem, words_at_once * sizeof(char));

            // Allocate words table
            //ret = cudaMalloc(&keys, words_at_once * sizeof(uint64_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for table in device reversed (1). Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&values, words_at_once * sizeof(uint32_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for table in device reversed (2). Error: %d\n", ret); exit(-1); }
            
            // ## POINTER SECTION 7
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif
            // We will give it the spot of the reference kmers/keys
            //address_checker = 0;
            base_ptr = &data_mem[0];
            ptr_seq_dev_mem = (char *) (base_ptr);
            //address_checker = realign_address(address_checker + words_at_once, 8);

            //ptr_keys = (uint64_t *) (base_ptr + address_checker);
            //address_checker = realign_address(address_checker + words_at_once * sizeof(uint64_t), 4);

            //ptr_values = (uint32_t *) (base_ptr + address_checker);
            //address_checker = realign_address(address_checker + words_at_once * sizeof(uint32_t), 4);


            // Load sequence chunk into ram
            ret = cudaMemcpy(ptr_seq_dev_mem, &ref_rev_seq_host[pos_in_ref], items_read_y, cudaMemcpyHostToDevice);
            if(ret != cudaSuccess){ fprintf(stderr, "Could not copy ref sequence to device reversed. Error: %d\n", ret); exit(-1); }

            // Run kmers
            ret = cudaMemset(ptr_keys_2, 0xFFFFFFFF, words_at_once * sizeof(uint64_t));
            ret = cudaMemset(ptr_values_2, 0xFFFFFFFF, words_at_once * sizeof(uint32_t));
            ret = cudaDeviceSynchronize();
            
            
            number_of_blocks = ((items_read_y - KMER_SIZE + 1))/64 + 1;

            if(number_of_blocks != 0)
            {
                kernel_index_global32<<<number_of_blocks, 64>>>(ptr_keys_2, ptr_values_2, ptr_seq_dev_mem, pos_in_ref, items_read_y);
    
                ret = cudaDeviceSynchronize();
                if(ret != cudaSuccess){ fprintf(stderr, "Could not compute kmers on ref reversed. Error: %d\n", ret); exit(-1); }
            }
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );

            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] words RC t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
#endif 

            //cudaFree(seq_dev_mem);

            ////////////////////////////////////////////////////////////////////////////////
            // Sort reference FORWARD kmers BUT REVERSED !
            ////////////////////////////////////////////////////////////////////////////////

            // ## POINTER SECTION 8
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif
            
            

            mergesort(ptr_keys_2, ptr_values_2, items_read_y, mgpu::less_t<uint64_t>(), context);
            ret = cudaDeviceSynchronize();

            if(ret != cudaSuccess){ fprintf(stderr, "MODERNGPU sorting failed on words reverse. Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }


            pos_in_ref += words_at_once;
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] sortwords RC t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
#endif 

            ////////////////////////////////////////////////////////////////////////////////
            // Generate hits for the current split BUT REVERSED !
            ////////////////////////////////////////////////////////////////////////////////

#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif
            uint32_t n_hits_found;
            if(fast == 2)
                n_hits_found = generate_hits_fast(max_hits, diagonals, hits, dict_x_keys, dict_y_keys, dict_x_values, dict_y_values, items_read_x, items_read_y, query_len, ref_len);
//            else
//#ifdef AVX512CUSTOM
//                n_hits_found = generate_hits_sensitive_avx512(max_hits, diagonals, hits, dict_x_keys, dict_y_keys, dict_x_values, dict_y_values, items_read_x, items_read_y, query_len, ref_len);
//#else
//                n_hits_found = generate_hits_sensitive(max_hits, diagonals, hits, dict_x_keys, dict_y_keys, dict_x_values, dict_y_values, items_read_x, items_read_y, query_len, ref_len, max_frequency, fast);
//#endif

            uint64_t mem_block = (max_hits)/32;
            fprintf(stdout, "-----DEBUG size of mem block ==:> %" PRIu64 "\n", mem_block * sizeof(uint64_t));


            // Set error status to zero
            ret = cudaMemset(ptr_device_error, 0x00000000, sizeof(int32_t));
            ret = cudaMemset(ptr_device_diagonals, 0x00000000,  max_hits * sizeof(uint64_t));
            
            

            // disabled right now for testing
            //kernel_hits<<<32, 32>>>(ptr_keys, ptr_keys_2, ptr_values, ptr_values_2, ptr_device_diagonals, (int32_t) mem_block, (int32_t) items_read_x, (int32_t) items_read_y, ptr_device_error, ref_len, ptr_hits_log);
            ret = cudaDeviceSynchronize();


            int32_t device_error;
            if(ret != cudaSuccess){ fprintf(stderr, "Error generating reverse hits on device. Error: %d\n", ret); exit(-1); }
            ret = cudaMemcpy(&device_error, ptr_device_error, sizeof(int32_t), cudaMemcpyDeviceToHost);
            if(ret != cudaSuccess){ fprintf(stderr, "Downloading error status on reverse hits generation. Error: %d\n", ret); exit(-1); }
            printf("debug from error hits : %d\n", device_error);
            if(device_error == -1) { fprintf(stderr, "Error generating reverse hits on device. Error: %d\n", device_error); exit(-1); }

            uint32_t * hits_log = (uint32_t *) malloc(32*sizeof(uint32_t)); memset(hits_log, 0x00000000, 32*sizeof(uint32_t));
            ret = cudaMemcpy(hits_log, ptr_hits_log, sizeof(uint32_t)*32, cudaMemcpyDeviceToHost);
            for(i=0; i<32; i++) n_hits_found += hits_log[i];
            free(hits_log);


#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );

            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] hits Q-RC t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
            fprintf(stdout, "[INFO] Generated %" PRIu32" hits on reversed split %d -> (%d%%)[%u,%u]{%u,%u}\n", n_hits_found, split, (int)((100*MIN((uint64_t)pos_in_ref, (uint64_t)ref_len))/(uint64_t)ref_len), pos_in_query, pos_in_ref, items_read_x, items_read_y);
#endif 

            ////////////////////////////////////////////////////////////////////////////////
            // Sort hits for the current split BUT REVERSED !
            ////////////////////////////////////////////////////////////////////////////////

            //ret = cudaMalloc(&device_diagonals, max_hits * sizeof(uint64_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for hits in device (1). Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&device_diagonals_buf, max_hits * sizeof(uint64_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for hits in device (2). Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&device_hits, max_hits * sizeof(uint32_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for hits in device (3). Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&device_hits_buf, max_hits * sizeof(uint32_t));
            //if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate memory for hits in device (4). Error: %d\n", ret); exit(-1); }

            // ## POINTER SECTION 9
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif
            base_ptr = &data_mem[0];
            address_checker = 0;
            address_checker = realign_address(address_checker, 8);
            uint64_t * ptr_device_diagonals = (uint64_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + max_hits * sizeof(uint64_t), 4);

            //uint64_t * ptr_device_diagonals_buf = (uint64_t *) (base_ptr + address_checker);
            //address_checker = realign_address(address_checker + max_hits * sizeof(uint64_t), 4);

            //uint32_t * ptr_device_hits = (uint32_t *) (base_ptr + address_checker);
            //address_checker = realign_address(address_checker + max_hits * sizeof(uint32_t), 4);

            //uint32_t * ptr_device_hits_buf = (uint32_t *) (base_ptr + address_checker);
            //address_checker = realign_address(address_checker + max_hits * sizeof(uint32_t), 4);

            // We will actually sort the diagonals with associated values 0,1,2... to n and use these to index the hits array
            // Not anymore: now just sort with dict y in the values to leverage work in the filter kernel
            //ret = cudaMemcpy(ptr_device_hits, ascending_numbers, n_hits_found*sizeof(uint32_t), cudaMemcpyHostToDevice);
            //if(ret != cudaSuccess){ fprintf(stderr, "Uploading device reverse hits. Error: %d\n", ret); exit(-1); }

            ret = cudaMemcpy(ptr_device_diagonals, diagonals, n_hits_found*sizeof(uint64_t), cudaMemcpyHostToDevice);
            if(ret != cudaSuccess){ fprintf(stderr, "Uploading device diagonals. Error: %d\n", ret); exit(-1); }

            //cub::DoubleBuffer<uint64_t> d_diagonals(ptr_device_diagonals, ptr_device_diagonals_buf);
            //cub::DoubleBuffer<uint32_t> d_hits(ptr_device_hits, ptr_device_hits_buf);
            //d_temp_storage = NULL;
            //temp_storage_bytes = 0;
            //cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes, d_diagonals, d_hits, n_hits_found);
            //ret = cudaDeviceSynchronize();
            //if(ret != cudaSuccess){ fprintf(stderr, "Bad pre-sorting (3). Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }

            // Allocate temporary storage
            //ret = cudaMalloc(&d_temp_storage, temp_storage_bytes);
            //if(ret != cudaSuccess){ fprintf(stderr, "Bad allocating of temp storage for hits sorting (1). Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }
            
            //cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes, d_diagonals, d_hits, n_hits_found);
            //ret = cudaDeviceSynchronize();
            //if(ret != cudaSuccess){ fprintf(stderr, "CUB sorting failed on hits. Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }


            mergesort(ptr_device_diagonals, n_hits_found, mgpu::less_t<uint64_t>(), context);

            ret = cudaDeviceSynchronize();

            if(ret != cudaSuccess){ fprintf(stderr, "MODERNGPU sorting failed on hits rev. Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }

            
            // Download hits (actually just number indices)
            // Not really: now y values

            //ret = cudaMemcpy(indexing_numbers, ptr_device_hits, n_hits_found*sizeof(uint32_t), cudaMemcpyDeviceToHost);
            //if(ret != cudaSuccess){ fprintf(stderr, "Downloading device hits. Error: %d\n", ret); exit(-1); }

            //ret = cudaMemcpy(diagonals, ptr_device_diagonals, n_hits_found*sizeof(uint64_t), cudaMemcpyDeviceToHost);
            //if(ret != cudaSuccess){ fprintf(stderr, "Downloading device diagonals. Error: %d\n", ret); exit(-1); }

#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );

            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] sortinghits Q-RC t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
#endif 



            memset(filtered_hits_x, 0x0000, n_hits_found * sizeof(uint32_t));
            memset(filtered_hits_y, 0x0000, n_hits_found * sizeof(uint32_t));
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif

            //kernel_filter_hits<<<n_hits_found/(32*32)+1, 32>>>(ptr_device_diagonals, ref_len, n_hits_found);
            //cudaProfilerStart();
            kernel_filter_hits_parallel<<<n_hits_found/(64)+1, 64>>>(ptr_device_diagonals, ref_len, n_hits_found);
            ret = cudaDeviceSynchronize();
            //cudaProfilerStop();
            if(ret != cudaSuccess){ fprintf(stderr, "FILTER HITS failed on query-ref-comp hits. Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }

            ret = cudaMemcpy(diagonals, ptr_device_diagonals, n_hits_found*sizeof(uint64_t), cudaMemcpyDeviceToHost);
            if(ret != cudaSuccess){ fprintf(stderr, "Downloading device diagonals. Error: %d\n", ret); exit(-1); }

            uint32_t n_hits_kept = filter_hits_cpu(diagonals, filtered_hits_x, filtered_hits_y, n_hits_found);
            //uint32_t n_hits_kept = filter_hits_reverse(diagonals, indexing_numbers, hits, filtered_hits_x, filtered_hits_y, n_hits_found);

#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );

            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] filterhits Q-RC t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
            fprintf(stdout, "[INFO] Remaining hits %" PRIu32"\n", n_hits_kept);
#endif 

            //printf("VALHALA 2\n");
            //continue;
            

            // Filtered hits are in order to diagonal (x-y)*l + x (PROVED)
            // Notice::::: These are sorted equally as with forward hits because the input sequence
            // Y has already been fully reversed and complemented :) 
            /*
            FILE * anything2 = fopen("onlyhits-reverse.csv", "wt");
            print_header(anything2, query_len, ref_len);
            for(i=0; i<n_hits_kept; i++){
                int64_t d = (filtered_hits_x[i] - filtered_hits_y[i]);
                uint64_t best_yStart = ref_len - filtered_hits_y[i] - 1;
                uint64_t best_yEnd = ref_len - (filtered_hits_y[i]+32) - 1;
                //int64_t d = filtered_hits_x[i] + best_yStart;
                fprintf(anything2, "Frag,%"PRId64",%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64",f,0,32,32,32,1.0,1.0,0,0\n", d, filtered_hits_x[i], best_yStart, filtered_hits_x[i]+32, best_yEnd);
            }
            fclose(anything2);
            */

            
            
            
            //ret = cudaFree(d_temp_storage);
            //ret = cudaFree(device_hits);
            //ret = cudaFree(device_diagonals);
            //ret = cudaFree(device_diagonals_buf);
            //ret = cudaFree(device_hits_buf);

            ////////////////////////////////////////////////////////////////////////////////
            // Generate REVERSE frags
            ////////////////////////////////////////////////////////////////////////////////

            // Allocate both sequences
            //ret = cudaMalloc(&seq_dev_mem, words_at_once * sizeof(char)); if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate for query sequence in device. Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&seq_dev_mem_aux, words_at_once * sizeof(char)); if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate for ref sequence in device. Error: %d\n", ret); exit(-1); }

            //ret = cudaMalloc(&device_filt_hits_x, max_hits * sizeof(uint32_t)); if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate for device filtered hits query. Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&device_filt_hits_y, max_hits * sizeof(uint32_t)); if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate for device filtered hits ref. Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&left_offset, max_hits * sizeof(uint32_t)); if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate for device offset left frags query. Error: %d\n", ret); exit(-1); }
            //ret = cudaMalloc(&right_offset, max_hits * sizeof(uint32_t)); if(ret != cudaSuccess){ fprintf(stderr, "Could not allocate for device offset right frags query. Error: %d\n", ret); exit(-1); }


            // ## POINTER SECTION 10
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif
            address_checker = 0;
            base_ptr = &data_mem[0];
            ptr_seq_dev_mem = (char *) (base_ptr);
            address_checker += words_at_once;

            ptr_seq_dev_mem_aux = (char *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + words_at_once, 4);

            uint32_t * ptr_device_filt_hits_x = (uint32_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + max_hits * sizeof(uint32_t), 4);

            uint32_t * ptr_device_filt_hits_y = (uint32_t *) (base_ptr + address_checker);
            address_checker = realign_address(address_checker + max_hits * sizeof(uint32_t), 4);

            //For half of the hits and frags we use the memory pool and for the other half we use the prealloc pool for sorting
            // Otherwise if there are too many hits they wont fit in just one pool

            uint64_t address_checker_pre_alloc = 0;
            char * base_pre_alloc_ptr = &pre_alloc[0];

            uint32_t * ptr_left_offset = (uint32_t *) (base_pre_alloc_ptr + address_checker_pre_alloc);
            address_checker_pre_alloc = realign_address(address_checker_pre_alloc + max_hits * sizeof(uint32_t), 32);

            uint32_t * ptr_right_offset = (uint32_t *) (base_pre_alloc_ptr + address_checker_pre_alloc);
            address_checker_pre_alloc = realign_address(address_checker_pre_alloc + max_hits * sizeof(uint32_t), 32);

            //printf("r %p\n", base_ptr + address_checker);

            ret = cudaMemcpy(ptr_seq_dev_mem, &query_seq_host[pos_in_query-words_at_once], MIN(query_len - (pos_in_query - words_at_once), words_at_once), cudaMemcpyHostToDevice); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy query sequence to device for frags. Error: %d\n", ret); exit(-1); }
            ret = cudaMemcpy(ptr_seq_dev_mem_aux, &ref_rev_seq_host[pos_in_ref-words_at_once], MIN(ref_len - (pos_in_ref - words_at_once), words_at_once), cudaMemcpyHostToDevice); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy ref sequence to device for frags. Error: %d\n", ret); exit(-1); }
            
            ret = cudaMemcpy(ptr_device_filt_hits_x, filtered_hits_x, n_hits_kept * sizeof(uint32_t), cudaMemcpyHostToDevice); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy filtered hits x in device. Error: %d\n", ret); exit(-1); }
            ret = cudaMemcpy(ptr_device_filt_hits_y, filtered_hits_y, n_hits_kept * sizeof(uint32_t), cudaMemcpyHostToDevice); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy filtered hits y in device. Error: %d\n", ret); exit(-1); }
            ret = cudaMemset(ptr_left_offset, 0x0, n_hits_kept * sizeof(uint32_t)); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy left offset in device. Error: %d\n", ret); exit(-1); }
            ret = cudaMemset(ptr_right_offset, 0x0, n_hits_kept * sizeof(uint32_t)); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy right offset in device. Error: %d\n", ret); exit(-1); }
            ret = cudaDeviceSynchronize();
            //
            //for(i=n_hits_kept-1; i>1; i--){
            //    printf(" Frag %" PRIu64" \t x: %.32s %" PRIu64"\n", i, &query_seq_host[filtered_hits_x[i]], filtered_hits_x[i]);
            //    printf(" \t\t y: %.32s %" PRIu64"\n", &ref_seq_host[filtered_hits_y[i]], filtered_hits_y[i]);
            //}

            //printf("VALHALA 3\n");
            //continue;


            //number_of_blocks = n_hits_kept; 
            number_of_blocks = (n_hits_kept / n_frags_per_block) + 1;

            //number_of_blocks = 100; 
            //printf("sending blocks: %u\n", number_of_blocks);
            //printf("We are sending: posinquery-wo=%u posinref-wo=%u MIN1=%u MIN2=%u\n", pos_in_query-words_at_once, pos_in_ref-words_at_once, MIN(pos_in_query, query_len), MIN(pos_in_ref, ref_len));


            number_of_blocks = (n_hits_kept / n_frags_per_block) + 1;

            if(number_of_blocks != 0)
            {
                // Plot twist: its the same kernel for forward and reverse since sequence is completely reversed
                kernel_frags_forward_register<<<number_of_blocks, threads_number>>>(ptr_device_filt_hits_x, ptr_device_filt_hits_y, ptr_left_offset, ptr_right_offset, ptr_seq_dev_mem, ptr_seq_dev_mem_aux, query_len, ref_len, pos_in_query-words_at_once, pos_in_ref-words_at_once, MIN(pos_in_query, query_len), MIN(pos_in_ref, ref_len), n_hits_kept, n_frags_per_block);

                ret = cudaDeviceSynchronize();
                if(ret != cudaSuccess){ fprintf(stderr, "Failed on generating forward frags. Error: %d -> %s\n", ret, cudaGetErrorString(cudaGetLastError())); exit(-1); }
            }
                


            ret = cudaMemcpy(host_left_offset, ptr_left_offset, n_hits_kept * sizeof(uint32_t), cudaMemcpyDeviceToHost); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy back left offset. Error: %d\n", ret); exit(-1); }
            ret = cudaMemcpy(host_right_offset, ptr_right_offset, n_hits_kept * sizeof(uint32_t), cudaMemcpyDeviceToHost); if(ret != cudaSuccess){ fprintf(stderr, "Could not copy back right offset. Error: %d\n", ret); exit(-1); }
#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] frags Q-RC t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
#endif 

            /*           
            FILE * anything = fopen("onlyfrags-reverse.csv", "wt");
            print_header(anything, query_len, ref_len);
            for(i=0; i<n_hits_kept; i++){
                uint64_t best_xStart = filtered_hits_x[i] - host_left_offset[i];
                uint64_t best_xEnd = filtered_hits_x[i] + host_right_offset[i];
                uint64_t best_yStart = filtered_hits_y[i] - host_left_offset[i];
                uint64_t best_yEnd = filtered_hits_y[i] + host_right_offset[i];
                int64_t d = (filtered_hits_x[i] + filtered_hits_y[i]);


                fprintf(anything, "hitx: %" PRIu64" hity: %" PRIu64" (d: %"PRId64") -> Frag,(%"PRId64"),%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64"\n", filtered_hits_x[i], filtered_hits_y[i], d, (int64_t)best_xStart+(int64_t)best_yStart, best_xStart, best_yStart, best_xEnd, best_yEnd, best_xEnd-best_xStart);
                //fprintf(anything, "Frag,%"PRId64",%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64",%" PRIu64",f,0,%" PRIu64",32,32,1.0,1.0,0,0\n", d, filtered_hits_x[i], filtered_hits_y[i], best_xStart, best_yStart, best_xEnd, best_yEnd, best_xEnd-best_xStart);
            }
            fclose(anything);
            */
            

            //cudaFree(seq_dev_mem);
            //cudaFree(seq_dev_mem_aux);
            //cudaFree(device_filt_hits_x);
            //cudaFree(device_filt_hits_y);
            //cudaFree(left_offset);
            //cudaFree(right_offset);

            
            //printf("VALHALA 4\n");
            //continue;

#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_start);
#endif

            filter_and_write_frags(filtered_hits_x, filtered_hits_y, host_left_offset, host_right_offset, n_hits_kept, out, 'r', ref_len, min_length);

#ifdef SHOWTIME
            clock_gettime(CLOCK_MONOTONIC, &HD_end);
            time_seconds += ( (uint64_t) HD_end.tv_sec - (uint64_t) HD_start.tv_sec ) ;
            time_nanoseconds += ( (uint64_t) HD_end.tv_nsec - (uint64_t) HD_start.tv_nsec );
            time_seconds *= BILLION;
            fprintf(stdout, "[INFO] filterFrags Q-RC t=%" PRIu64 " ns\n", time_seconds + time_nanoseconds);
            time_seconds = 0;
            time_nanoseconds = 0;
#endif 

        }

        pos_in_ref = 0;


        ++split;
    }

    fclose(out);
    
    
    
    
    

    fprintf(stdout, "[INFO] Completed\n");

    fclose(query);
    fclose(ref);

    /*
    free(query_seq_host);
    free(ref_seq_host);
    free(ref_rev_seq_host);
    free(dict_x_keys); 
    free(dict_x_values); 
    free(dict_y_keys); 
    free(dict_y_values); 
    free(hits); 
    free(filtered_hits_x); 
    free(filtered_hits_y); 
    free(host_left_offset); 
    free(host_right_offset); 
    free(diagonals); 
    free(ascending_numbers); 
    free(indexing_numbers); 
    */

    cudaFree(data_mem);
    cudaFreeHost(host_pinned_mem);
    /*
    cudaFreeHost(query_seq_host);
    cudaFreeHost(ref_seq_host);
    cudaFreeHost(ref_rev_seq_host);
    cudaFreeHost(dict_x_keys); 
    cudaFreeHost(dict_x_values); 
    cudaFreeHost(dict_y_keys); 
    cudaFreeHost(dict_y_values); 
    cudaFreeHost(hits); 
    cudaFreeHost(filtered_hits_x); 
    cudaFreeHost(filtered_hits_y); 
    cudaFreeHost(host_left_offset); 
    cudaFreeHost(host_right_offset); 
    cudaFreeHost(diagonals); 
    cudaFreeHost(ascending_numbers); 
    cudaFreeHost(indexing_numbers); 
    */

    return 0;
}

void print_header(FILE * out, uint32_t query_len, uint32_t ref_len){

    fprintf(out, "All by-Identity Ungapped Fragments (Hits based approach)\n");
    fprintf(out, "[Abr.98/Apr.2010/Dec.2011 -- <ortrelles@uma.es>\n");
    fprintf(out, "SeqX filename : undef\n");
    fprintf(out, "SeqY filename : undef\n");
    fprintf(out, "SeqX name : undef\n");
    fprintf(out, "SeqY name : undef\n");
    fprintf(out, "SeqX length : %" PRIu32"\n", query_len);
    fprintf(out, "SeqY length : %" PRIu32"\n", ref_len);
    fprintf(out, "Min.fragment.length : undef\n");
    fprintf(out, "Min.Identity : undef\n");
    fprintf(out, "Tot Hits (seeds) : undef\n");
    fprintf(out, "Tot Hits (seeds) used: undef\n");
    fprintf(out, "Total fragments : undef\n");
    fprintf(out, "========================================================\n");
    fprintf(out, "Total CSB: 0\n");
    fprintf(out, "========================================================\n");
    fprintf(out, "Type,xStart,yStart,xEnd,yEnd,strand(f/r),block,length,score,ident,similarity,%%ident,SeqX,SeqY\n");
}


uint64_t memory_allocation_chooser(uint64_t total_memory)
{
   

    if(total_memory <= 4340179200) return 100*1024*1024;
    else if(total_memory <= 6442450944) return 150*1024*1024;
    else if(total_memory <= 8689934592) return 200*1024*1024;
    return 300*1024*1024;
 
}

char * dump_memory_region(char * ptr_pointer, uint64_t size){

    char * anything = (char *) malloc(size*sizeof(char));
    int ret = cudaMemcpy(anything, ptr_pointer, size * sizeof(char), cudaMemcpyDeviceToHost);
    if(ret != cudaSuccess){ fprintf(stderr, "Dumping data region. Error: %d\n", ret); exit(-1); }
    return anything;
}





