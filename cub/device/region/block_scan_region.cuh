/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2013, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/**
 * \file
 * cub::BlockScanRegion implements a stateful abstraction of CUDA thread blocks for participating in device-wide prefix scan across a region of tiles.
 */

#pragma once

#include <iterator>

#include "device_scan_types.cuh"
#include "../../block/block_load.cuh"
#include "../../block/block_store.cuh"
#include "../../block/block_scan.cuh"
#include "../../grid/grid_queue.cuh"
#include "../../iterator/cache_modified_input_iterator.cuh"
#include "../../util_namespace.cuh"

/// Optional outer namespace(s)
CUB_NS_PREFIX

/// CUB namespace
namespace cub {


/******************************************************************************
 * Tuning policy types
 ******************************************************************************/

/**
 * Parameterizable tuning policy type for BlockScanRegion
 */
template <
    int                         _BLOCK_THREADS,                 ///< Threads per thread block
    int                         _ITEMS_PER_THREAD,              ///< Items per thread (per tile of input)
    BlockLoadAlgorithm          _LOAD_ALGORITHM,                ///< The BlockLoad algorithm to use
    bool                        _LOAD_WARP_TIME_SLICING,        ///< Whether or not only one warp's worth of shared memory should be allocated and time-sliced among block-warps during any load-related data transpositions (versus each warp having its own storage)
    CacheLoadModifier           _LOAD_MODIFIER,                 ///< Cache load modifier for reading input elements
    BlockStoreAlgorithm         _STORE_ALGORITHM,               ///< The BlockStore algorithm to use
    bool                        _STORE_WARP_TIME_SLICING,       ///< Whether or not only one warp's worth of shared memory should be allocated and time-sliced among block-warps during any store-related data transpositions (versus each warp having its own storage)
    BlockScanAlgorithm          _SCAN_ALGORITHM>                ///< The BlockScan algorithm to use
struct BlockScanRegionPolicy
{
    enum
    {
        BLOCK_THREADS           = _BLOCK_THREADS,               ///< Threads per thread block
        ITEMS_PER_THREAD        = _ITEMS_PER_THREAD,            ///< Items per thread (per tile of input)
        LOAD_WARP_TIME_SLICING  = _LOAD_WARP_TIME_SLICING,      ///< Whether or not only one warp's worth of shared memory should be allocated and time-sliced among block-warps during any load-related data transpositions (versus each warp having its own storage)
        STORE_WARP_TIME_SLICING = _STORE_WARP_TIME_SLICING,     ///< Whether or not only one warp's worth of shared memory should be allocated and time-sliced among block-warps during any store-related data transpositions (versus each warp having its own storage)
    };

    static const BlockLoadAlgorithm     LOAD_ALGORITHM          = _LOAD_ALGORITHM;          ///< The BlockLoad algorithm to use
    static const CacheLoadModifier      LOAD_MODIFIER           = _LOAD_MODIFIER;           ///< Cache load modifier for reading input elements
    static const BlockStoreAlgorithm    STORE_ALGORITHM         = _STORE_ALGORITHM;         ///< The BlockStore algorithm to use
    static const BlockScanAlgorithm     SCAN_ALGORITHM    = _SCAN_ALGORITHM;    ///< The BlockScan algorithm to use
};


/******************************************************************************
 * Thread block abstractions
 ******************************************************************************/

/**
 * \brief BlockScanRegion implements a stateful abstraction of CUDA thread blocks for participating in device-wide prefix scan across a region of tiles.
 */
template <
    typename BlockScanRegionPolicy,     ///< Parameterized BlockScanRegionPolicy tuning policy type
    typename InputIterator,             ///< Random-access input iterator type
    typename OutputIterator,            ///< Random-access output iterator type
    typename ScanOp,                    ///< Scan functor type
    typename Identity,                  ///< Identity element type (cub::NullType for inclusive scan)
    typename Offset>                    ///< Signed integer type for global offsets
struct BlockScanRegion
{
    //---------------------------------------------------------------------
    // Types and constants
    //---------------------------------------------------------------------

    // Data type of input iterator
    typedef typename std::iterator_traits<InputIterator>::value_type T;

    // Input iterator wrapper type
    typedef typename If<IsPointer<InputIterator>::VALUE,
            CacheModifiedInputIterator<BlockScanRegionPolicy::LOAD_MODIFIER, T, Offset>,    // Wrap the native input pointer with CacheModifiedInputIterator
            InputIterator>::Type                                                            // Directly use the supplied input iterator type
        WrappedInputIterator;

    // Constants
    enum
    {
        INCLUSIVE           = Equals<Identity, NullType>::VALUE,            // Inclusive scan if no identity type is provided
        BLOCK_THREADS       = BlockScanRegionPolicy::BLOCK_THREADS,
        ITEMS_PER_THREAD    = BlockScanRegionPolicy::ITEMS_PER_THREAD,
        TILE_ITEMS          = BLOCK_THREADS * ITEMS_PER_THREAD,
    };

    // Parameterized BlockLoad type
    typedef BlockLoad<
            WrappedInputIterator,
            BlockScanRegionPolicy::BLOCK_THREADS,
            BlockScanRegionPolicy::ITEMS_PER_THREAD,
            BlockScanRegionPolicy::LOAD_ALGORITHM,
            BlockScanRegionPolicy::LOAD_WARP_TIME_SLICING>
        BlockLoadT;

    // Parameterized BlockStore type
    typedef BlockStore<
            OutputIterator,
            BlockScanRegionPolicy::BLOCK_THREADS,
            BlockScanRegionPolicy::ITEMS_PER_THREAD,
            BlockScanRegionPolicy::STORE_ALGORITHM,
            BlockScanRegionPolicy::STORE_WARP_TIME_SLICING>
        BlockStoreT;

    // Tile status descriptor type
    typedef LookbackTileDescriptor<T> TileDescriptor;

    // Parameterized BlockScan type
    typedef BlockScan<
            T,
            BlockScanRegionPolicy::BLOCK_THREADS,
            BlockScanRegionPolicy::SCAN_ALGORITHM>
        BlockScanT;

    // Callback type for obtaining tile prefix during block scan
    typedef LookbackBlockPrefixCallbackOp<
            T,
            ScanOp>
        LookbackPrefixCallbackOp;

    // Stateful BlockScan prefix callback type for managing a running total while scanning consecutive tiles
    typedef RunningBlockPrefixCallbackOp<
            T,
            ScanOp>
        RunningPrefixCallbackOp;

    // Shared memory type for this threadblock
    struct _TempStorage
    {
        union
        {
            typename BlockLoadT::TempStorage    load;       // Smem needed for tile loading
            typename BlockStoreT::TempStorage   store;      // Smem needed for tile storing
            struct
            {
                typename LookbackPrefixCallbackOp::TempStorage  prefix;     // Smem needed for cooperative prefix callback
                typename BlockScanT::TempStorage                scan;       // Smem needed for tile scanning
            };
        };

        Offset tile_idx;   // Shared tile index
    };

    // Alias wrapper allowing storage to be unioned
    struct TempStorage : Uninitialized<_TempStorage> {};


    //---------------------------------------------------------------------
    // Per-thread fields
    //---------------------------------------------------------------------

    _TempStorage                &temp_storage;      ///< Reference to temp_storage
    WrappedInputIterator        d_in;               ///< Input data
    OutputIterator              d_out;              ///< Output data
    ScanOp                      scan_op;            ///< Binary scan operator
    Identity                    identity;           ///< Identity element



    //---------------------------------------------------------------------
    // Block scan utility methods (first tile)
    //---------------------------------------------------------------------

    /**
     * Exclusive scan specialization
     */
    template <typename _ScanOp, typename _Identity>
    __device__ __forceinline__
    void ScanBlock(T (&items)[ITEMS_PER_THREAD], _ScanOp scan_op, _Identity identity, T& block_aggregate)
    {
        BlockScanT(temp_storage.scan).ExclusiveScan(items, items, identity, scan_op, block_aggregate);
    }

    /**
     * Exclusive sum specialization
     */
    template <typename _Identity>
    __device__ __forceinline__
    void ScanBlock(T (&items)[ITEMS_PER_THREAD], Sum scan_op, _Identity identity, T& block_aggregate)
    {
        BlockScanT(temp_storage.scan).ExclusiveSum(items, items, block_aggregate);
    }

    /**
     * Inclusive scan specialization
     */
    template <typename _ScanOp>
    __device__ __forceinline__
    void ScanBlock(T (&items)[ITEMS_PER_THREAD], _ScanOp scan_op, NullType identity, T& block_aggregate)
    {
        BlockScanT(temp_storage.scan).InclusiveScan(items, items, scan_op, block_aggregate);
    }

    /**
     * Inclusive sum specialization
     */
    __device__ __forceinline__
    void ScanBlock(T (&items)[ITEMS_PER_THREAD], Sum scan_op, NullType identity, T& block_aggregate)
    {
        BlockScanT(temp_storage.scan).InclusiveSum(items, items, block_aggregate);
    }

    //---------------------------------------------------------------------
    // Block scan utility methods (subsequent tiles)
    //---------------------------------------------------------------------

    /**
     * Exclusive scan specialization (with prefix from predecessors)
     */
    template <typename _ScanOp, typename _Identity, typename PrefixCallback>
    __device__ __forceinline__
    void ScanBlock(T (&items)[ITEMS_PER_THREAD], _ScanOp scan_op, _Identity identity, T& block_aggregate, PrefixCallback &prefix_op)
    {
        BlockScanT(temp_storage.scan).ExclusiveScan(items, items, identity, scan_op, block_aggregate, prefix_op);
    }

    /**
     * Exclusive sum specialization (with prefix from predecessors)
     */
    template <typename _Identity, typename PrefixCallback>
    __device__ __forceinline__
    void ScanBlock(T (&items)[ITEMS_PER_THREAD], Sum scan_op, _Identity identity, T& block_aggregate, PrefixCallback &prefix_op)
    {
        BlockScanT(temp_storage.scan).ExclusiveSum(items, items, block_aggregate, prefix_op);
    }

    /**
     * Inclusive scan specialization (with prefix from predecessors)
     */
    template <typename _ScanOp, typename PrefixCallback>
    __device__ __forceinline__
    void ScanBlock(T (&items)[ITEMS_PER_THREAD], _ScanOp scan_op, NullType identity, T& block_aggregate, PrefixCallback &prefix_op)
    {
        BlockScanT(temp_storage.scan).InclusiveScan(items, items, scan_op, block_aggregate, prefix_op);
    }

    /**
     * Inclusive sum specialization (with prefix from predecessors)
     */
    template <typename PrefixCallback>
    __device__ __forceinline__
    void ScanBlock(T (&items)[ITEMS_PER_THREAD], Sum scan_op, NullType identity, T& block_aggregate, PrefixCallback &prefix_op)
    {
        BlockScanT(temp_storage.scan).InclusiveSum(items, items, block_aggregate, prefix_op);
    }


    //---------------------------------------------------------------------
    // Constructor
    //---------------------------------------------------------------------

    // Constructor
    __device__ __forceinline__
    BlockScanRegion(
        TempStorage                 &temp_storage,      ///< Reference to temp_storage
        InputIterator               d_in,               ///< Input data
        OutputIterator              d_out,              ///< Output data
        ScanOp                      scan_op,            ///< Binary scan operator
        Identity                    identity)           ///< Identity element
    :
        temp_storage(temp_storage.Alias()),
        d_in(d_in),
        d_out(d_out),
        scan_op(scan_op),
        identity(identity)
    {}


    //---------------------------------------------------------------------
    // Cooperatively scan a device-wide sequence of tiles with other CTAs
    //---------------------------------------------------------------------

    /**
     * Process a tile of input (dynamic domino scan)
     */
    template <bool FULL_TILE>
    __device__ __forceinline__ void ConsumeTile(
        Offset                      num_items,          ///< Total number of input items
        int                         tile_idx,           ///< Tile index
        Offset                      block_offset,       ///< Tile offset
        TileDescriptor              *d_tile_status)     ///< Global list of tile status
    {
        // Load items
        T items[ITEMS_PER_THREAD];

        if (FULL_TILE)
            BlockLoadT(temp_storage.load).Load(d_in + block_offset, items);
        else
            BlockLoadT(temp_storage.load).Load(d_in + block_offset, items, num_items - block_offset);

        __syncthreads();

        // Perform tile scan
        T block_aggregate;
        if (tile_idx == 0)
        {
            // Scan first tile
            ScanBlock(items, scan_op, identity, block_aggregate);

            // Update tile status if there may be successor tiles (i.e., this tile is full)
            if (FULL_TILE && (threadIdx.x == 0))
                TileDescriptor::SetPrefix(d_tile_status, block_aggregate);
        }
        else
        {
            // Scan non-first tile
            LookbackPrefixCallbackOp prefix_op(d_tile_status, temp_storage.prefix, scan_op, tile_idx);
            ScanBlock(items, scan_op, identity, block_aggregate, prefix_op);
        }

        __syncthreads();

        // Store items
        if (FULL_TILE)
            BlockStoreT(temp_storage.store).Store(d_out + block_offset, items);
        else
            BlockStoreT(temp_storage.store).Store(d_out + block_offset, items, num_items - block_offset);
    }


    /**
     * Dequeue and scan tiles of items as part of a dynamic domino scan
     */
    __device__ __forceinline__ void ConsumeRegion(
        int                     num_items,          ///< Total number of input items
        GridQueue<int>          queue,              ///< Queue descriptor for assigning tiles of work to thread blocks
        TileDescriptor          *d_tile_status)     ///< Global list of tile status
    {
#if CUB_PTX_VERSION < 200

        // No concurrent kernels allowed and blocks are launched in increasing order, so just assign one tile per block (up to 65K blocks)
        int     tile_idx        = blockIdx.x;
        Offset  block_offset    = Offset(TILE_ITEMS) * tile_idx;

        if (block_offset + TILE_ITEMS <= num_items)
            ConsumeTile<true>(num_items, tile_idx, block_offset, d_tile_status);
        else if (block_offset < num_items)
            ConsumeTile<false>(num_items, tile_idx, block_offset, d_tile_status);

#else

        // Get first tile
        if (threadIdx.x == 0)
            temp_storage.tile_idx = queue.Drain(1);

        __syncthreads();

        int tile_idx = temp_storage.tile_idx;
        Offset block_offset = Offset(TILE_ITEMS) * tile_idx;

        while (block_offset + TILE_ITEMS <= num_items)
        {
            // Consume full tile
            ConsumeTile<true>(num_items, tile_idx, block_offset, d_tile_status);

            // Get next tile
            if (threadIdx.x == 0)
                temp_storage.tile_idx = queue.Drain(1);

            __syncthreads();

            tile_idx = temp_storage.tile_idx;
            block_offset = Offset(TILE_ITEMS) * tile_idx;
        }

        // Consume a partially-full tile
        if (block_offset < num_items)
        {
            ConsumeTile<false>(num_items, tile_idx, block_offset, d_tile_status);
        }
#endif

    }


    //---------------------------------------------------------------------
    // Scan an sequence of consecutive tiles (independent of other thread blocks)
    //---------------------------------------------------------------------

    /**
     * Process a tile of input
     */
    template <
        bool                FULL_TILE,
        bool                FIRST_TILE>
    __device__ __forceinline__ void ConsumeTile(
        Offset                      block_offset,               ///< Tile offset
        RunningPrefixCallbackOp     &prefix_op,                 ///< Running prefix operator
        int                         valid_items = TILE_ITEMS)   ///< Number of valid items in the tile
    {
        // Load items
        T items[ITEMS_PER_THREAD];

        if (FULL_TILE)
            BlockLoadT(temp_storage.load).Load(d_in + block_offset, items);
        else
            BlockLoadT(temp_storage.load).Load(d_in + block_offset, items, valid_items);

        __syncthreads();

        // Block scan
        T block_aggregate;
        if (FIRST_TILE)
        {
            ScanBlock(items, scan_op, identity, block_aggregate);
            prefix_op.running_total = block_aggregate;
        }
        else
        {
            ScanBlock(items, scan_op, identity, block_aggregate, prefix_op);
        }

        __syncthreads();

        // Store items
        if (FULL_TILE)
            BlockStoreT(temp_storage.store).Store(d_out + block_offset, items);
        else
            BlockStoreT(temp_storage.store).Store(d_out + block_offset, items, valid_items);
    }


    /**
     * Scan a consecutive share of input tiles
     */
    __device__ __forceinline__ void ConsumeRegion(
        Offset   block_offset,      ///< [in] Threadblock begin offset (inclusive)
        Offset   block_end)         ///< [in] Threadblock end offset (exclusive)
    {
        RunningBlockPrefixCallbackOp<T, ScanOp> prefix_op(scan_op);

        if (block_offset + TILE_ITEMS <= block_end)
        {
            // Consume first tile of input (full)
            ConsumeTile<true, true>(block_offset, prefix_op);
            block_offset += TILE_ITEMS;

            // Consume subsequent full tiles of input
            while (block_offset + TILE_ITEMS <= block_end)
            {
                ConsumeTile<true, false>(block_offset, prefix_op);
                block_offset += TILE_ITEMS;
            }

            // Consume a partially-full tile
            if (block_offset < block_end)
            {
                int valid_items = block_end - block_offset;
                ConsumeTile<false, false>(block_offset, prefix_op, valid_items);
            }
        }
        else
        {
            // Consume the first tile of input (partially-full)
            int valid_items = block_end - block_offset;
            ConsumeTile<false, true>(block_offset, prefix_op, valid_items);
        }
    }


    /**
     * Scan a consecutive share of input tiles, seeded with the specified prefix value
     */
    __device__ __forceinline__ void ConsumeRegion(
        Offset  block_offset,                       ///< [in] Threadblock begin offset (inclusive)
        Offset  block_end,                          ///< [in] Threadblock end offset (exclusive)
        T       prefix)                             ///< [in] The prefix to apply to the scan segment
    {
        RunningBlockPrefixCallbackOp<T, ScanOp> prefix_op(prefix, scan_op);

        // Consume full tiles of input
        while (block_offset + TILE_ITEMS <= block_end)
        {
            ConsumeTile<true, false>(block_offset, prefix_op);
            block_offset += TILE_ITEMS;
        }

        // Consume a partially-full tile
        if (block_offset < block_end)
        {
            int valid_items = block_end - block_offset;
            ConsumeTile<false, false>(block_offset, prefix_op, valid_items);
        }
    }

};


}               // CUB namespace
CUB_NS_POSTFIX  // Optional outer namespace(s)

