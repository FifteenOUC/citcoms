// -*- C++ -*-
//
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//
//  <LicenseText>
//
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//

#if !defined(pyCitcom_Sink_h)
#define pyCitcom_Sink_h

#include <vector>
#include "mpi.h"
#include "utility.h"

class BoundedMesh;


class Sink {
protected:
    MPI_Comm comm;
    std::vector<int> source;
    std::vector<int> numSrcNodes;
    std::vector<int> beginSrcNodes;
    Array2D<int,1> meshNode_;
    const int numMeshNodes;
    int me;

public:
    Sink(MPI_Comm comm, int nsrc, const BoundedMesh& mesh);
    virtual ~Sink() {};

    inline int size() const {return meshNode_.size();}
    inline int meshNode(int n) const {return meshNode_[0][n];}

    template <class T, int N>
    void recvArray2D(Array2D<T,N>& array) const;

    template <class T1, int N1, class T2, int N2>
    void recvArray2D(Array2D<T1,N1>& array1,
		     Array2D<T2,N2>& array2) const;

private:
    void checkCommSize(int nsrc) const;
    void sendMesh(const BoundedMesh& mesh) const;
    void recvMeshNode();
    void recvSourceSize();
    void sumSourceSize();
    void testMeshNode() const;

};


template <class T, int N>
void Sink::recvArray2D(Array2D<T,N>& array) const
{
#ifdef DEBUG
    if(size() != array.size()) {
	journal::firewall_t firewall("Sink");
	firewall << journal::loc(__HERE__)
		 << "Sink: inconsistenet array size" << journal::end;
	throw std::out_of_range("Sink");
    }
#endif

    std::vector<MPI_Request> request;
    request.reserve(source.size());

    for(size_t i=0; i<source.size(); i++)
	if(numSrcNodes[i]) {
	    request.push_back(MPI_Request());
	    array.receive(comm, source[i], beginSrcNodes[i],
			  numSrcNodes[i], request.back());
	}

    util::waitRequest(request);
}


template <class T1, int N1, class T2, int N2>
void Sink::recvArray2D(Array2D<T1,N1>& array1,
		       Array2D<T2,N2>& array2) const
{
#ifdef DEBUG
    if(size() != array1.size() || size() != array2.size()) {
	journal::firewall_t firewall("Sink");
	firewall << journal::loc(__HERE__)
		 << "Sink: inconsistenet array size" << journal::end;
	throw std::out_of_range("Sink");
    }
#endif

    std::vector<MPI_Request> request;
    request.reserve(2*source.size());

    for(size_t i=0; i<source.size(); i++)
	if(numSrcNodes[i]) {
	    request.push_back(MPI_Request());
	    array1.receive(comm, source[i], beginSrcNodes[i],
			   numSrcNodes[i], request.back());

	    request.push_back(MPI_Request());
	    array2.receive(comm, source[i], beginSrcNodes[i],
			   numSrcNodes[i], request.back());
	}

    util::waitRequest(request);
}


#endif

// version
// $Id: Sink.h,v 1.3 2003/11/11 19:29:27 tan2 Exp $

// End of file