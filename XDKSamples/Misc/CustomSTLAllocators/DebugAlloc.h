//-----------------------------------------------------------------------------
// File: DebugAlloc.h
//
// Desc: Custom STL allocator that adds checking for heap corruption and
//       supports heap statistics. Actual allocations are done with 
//       HeapAlloc on the default XBE heap. Every time an allocation or
//       deallocation is done the heap is validated.
//
// Hist: 10.11.02 - New for November 2002 XDK release
//
// Example Usage 1:
//
//     // All allocations for v will be logged
//     std::vector< int, DebugAlloc< int > > v;
//
// Example Usage 2:
//
//     // All allocations for v will be logged
//     typedef DebugAlloc< int > MyIntAlloc;
//     typedef std::vector< int, MyIntAlloc > MyIntVector;
//     MyIntVector v;
//
// Example Usage 3:
//
//     // Track statistics
//     typedef DebugAlloc< int > MyIntAlloc;
//     typedef std::vector< int, MyIntAlloc > MyIntVector;
//     MyIntVector v;
//     v.push_back( 1 );
//     DWORD dwBytesAllocated = v.get_allocator().GetBytesAllocated();
//
// Copyright (c) Microsoft Corporation. All rights reserved.
//-----------------------------------------------------------------------------
#pragma once
#if !defined(DEBUG_ALLOC_H)
#define DEBUG_ALLOC_H

#include <memory>
#include <cassert>
#include <xtl.h>


//-----------------------------------------------------------------------------
// Name: DebugAllocStats
// Desc: One tally of what this allocator has outstanding, shared by every
//       instance. The statistics have to belong to the allocations rather than
//       to an allocator object: a container is handed a copy of the allocator
//       it was built with and rebinds it for its node type, so a block is
//       routinely allocated through one instance and freed through another.
//       Counters kept per instance are then decremented on an instance that
//       never counted the allocation, which trips the assertions in
//       deallocate() below. (Keeping them per instance happened to work
//       against the VC++ 7.x library this sample was written for, which gave
//       each container a single long-lived allocator object.)
//-----------------------------------------------------------------------------
struct DebugAllocStats
{
    DWORD dwAllocCount;         // Number of outstanding allocations
    DWORD dwBytesAllocated;     // Number of bytes outstanding
};

inline DebugAllocStats& GetDebugAllocStats()
{
    static DebugAllocStats stats = { 0, 0 };
    return stats;
}


//-----------------------------------------------------------------------------
// Name: DebugAlloc()
// Desc: Allocator that validates the heap and tracks allocations
//-----------------------------------------------------------------------------
template< typename T >
class DebugAlloc
{
public:

    //-------------------------------------------------------------------------
    // Boilerplate allocator typedefs
    //-------------------------------------------------------------------------
    typedef size_t    size_type;
    typedef ptrdiff_t difference_type;
    typedef T*        pointer;
    typedef const T*  const_pointer;
    typedef T&        reference;
    typedef const T&  const_reference;
    typedef T         value_type;

    //-------------------------------------------------------------------------
    // Constructors/Destructor
    //-------------------------------------------------------------------------
    // Nothing to carry: the statistics live with the allocations, so a copy or a
    // rebind of this allocator is already looking at the same tally.
    DebugAlloc()
    {
    }

    DebugAlloc( const DebugAlloc< T >& )
    {
    }

    template< typename U >
    DebugAlloc( const DebugAlloc< U >& )
    {
    }

    ~DebugAlloc()
    {
        // Validate the heap
        #ifdef _DEBUG
        if( !HeapValidate( GetProcessHeap(), 0, NULL ) )
        {
            OutputDebugStringA( "Heap corrupted" );
            DebugBreak();
        }
        #endif
    }

    //-------------------------------------------------------------------------
    // Boilerplate allocator functions
    //-------------------------------------------------------------------------
    template< typename U >
    struct rebind
    {
        typedef DebugAlloc< U > other;
    };

    pointer address( reference x ) const
    {   
        return &x;
    }

    const_pointer address( const_reference x ) const
    {
        return &x;
    }

    void construct( pointer p, const T& val )
    {
        new ((void *)p) T(val); // placement new
    }

    void destroy( pointer p )
    {
        (p)->~T(); // in-place destruction
    }

    size_t max_size() const // maximum array size
    {
        size_t nCount = (size_t)( -1 ) / sizeof ( T );
        return( 0 < nCount ? nCount : 1 );
    }

    //-------------------------------------------------------------------------
    // Name: allocate
    // Desc: Allocates memory using HeapAlloc
    //-------------------------------------------------------------------------
    pointer allocate( size_type nCount )
    {
        return allocate( nCount, NULL );
    }

    pointer allocate( size_type nCount, const void* /* pHint */ )
    {
        DWORD dwBytes = nCount * sizeof( T );
        pointer p = (pointer)HeapAlloc( GetProcessHeap(), 0, dwBytes );
        
        // For C++ Standard compliance, throw bad_alloc on error.
        // If your code is expecting NULL in failure cases, remove these lines.
        if( p == NULL )
        {
            DebugBreak();
            throw std::bad_alloc();
        }
            
        // Track statistics. Count what the heap actually handed out, so the running
        // total matches what HeapSize reports back in deallocate().
        DebugAllocStats& stats = GetDebugAllocStats();
        ++stats.dwAllocCount;
        stats.dwBytesAllocated += HeapSize( GetProcessHeap(), 0, p );
        
        // Validate the heap
        #ifdef _DEBUG
        if( !HeapValidate( GetProcessHeap(), 0, NULL ) )
        {
            DebugBreak();
            throw std::bad_alloc();
        }
        #endif
            
        return p;
    }

    //-------------------------------------------------------------------------
    // Name: deallocate
    // Desc: Deallocate memory using HeapFree
    //-------------------------------------------------------------------------
    void deallocate( pointer p, size_type /* nCount */ )
    {
        if( p == NULL )
            return;

        // Find out the size of the allocation
        DWORD dwBytes = HeapSize( GetProcessHeap(), 0, p );

        DebugAllocStats& stats = GetDebugAllocStats();

        assert( stats.dwBytesAllocated >= dwBytes );
        stats.dwBytesAllocated -= dwBytes;

        // Track statistics
        assert( stats.dwAllocCount > 0 );
        --stats.dwAllocCount;
        
        // Free the memory
        HeapFree( GetProcessHeap(), 0, p );
    }

    //-------------------------------------------------------------------------
    // Accessor functions
    //-------------------------------------------------------------------------
    DWORD GetAllocationCount() const
    {
        return GetDebugAllocStats().dwAllocCount;
    }
    
    DWORD GetBytesAllocated() const
    {
        return GetDebugAllocStats().dwBytesAllocated;
    }
    
private:

    DebugAlloc< T >& operator=( const DebugAlloc< T >& );
    
};


//-----------------------------------------------------------------------------
// DebugAlloc standard template operators
//-----------------------------------------------------------------------------
template< typename T, typename U >
inline bool operator==( const DebugAlloc< T >&, const DebugAlloc< U >& )
{
    return true;
}

template< typename T, typename U >
inline bool operator!=( const DebugAlloc< T >&, const DebugAlloc< U >& )
{
    return false;
}


//-----------------------------------------------------------------------------
// Specialize for void
//-----------------------------------------------------------------------------
template<>
class DebugAlloc< void >
{
public:

    //-------------------------------------------------------------------------
    // Boilerplate allocator typedefs; no references to void possible
    //-------------------------------------------------------------------------
    typedef void*       pointer;
    typedef const void* const_pointer;
    typedef void        value_type;

    //-------------------------------------------------------------------------
    // Constructors
    //-------------------------------------------------------------------------
    DebugAlloc()
    {
    }

    template< typename U >
    DebugAlloc( const DebugAlloc< U >& )
    {
    }

    //-------------------------------------------------------------------------
    // Boilerplate rebind
    //-------------------------------------------------------------------------
    template< typename U >
    struct rebind
    {
        typedef DebugAlloc< U > other;
    };
};


#endif // DEBUG_ALLOC_H
