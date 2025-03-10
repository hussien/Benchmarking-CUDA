#ifndef DIRECTIONALGRAPH_H_
#define DIRECTIONALGRAPH_H_
/*
 * DirectionalGraph.h
 *
 *  Created on: Jul 1, 2010
 *      Author: Diogo Sampaio
 */
#include <iostream>
#include <set>
#include <map>
using namespace std;

namespace graph_utils {
class DirectionalGraph
{
	public:
		//TODO: Make this as a template class, so can use other types as node_type, might need to change set and map to unordered and a class to draw them as dot friendly
		typedef unsigned int node_type;

		/* A set of nodes of a directional graph */
		typedef set<node_type> node_set;
		typedef node_set::iterator node_iterator;
		typedef node_set::const_iterator const_node_iterator;

		/* Map every node to a list[set] of edges[arrows] */
		typedef map<node_type, node_set> arrows_map;

		typedef arrows_map::iterator arrow_iterator;

		typedef pair<int, node_iterator> node_action_info;

	protected:
		/*!\brief The set with the graph nodes */
		set<node_type> nodes;
		/*!\brief For each node, maps to which other nodes it has a edge[arrow] going to */
		map<node_type, node_set> inArrows;
		/*!\brief For each node, maps from which other nodes it has a edge[arrow] coming from */
		map<node_type, node_set> outArrows;

	public:
		~DirectionalGraph();
		void clear();
		void insertNode( const node_type &nodeId );
		size_t nodesCount() const;
		const_node_iterator getBeginNode() const;
		const_node_iterator getEndNode() const;
		const_node_iterator findNode( const node_type &nodeId ) const;
		bool hasNode( const node_type nodeId ) const;
		bool eraseNode( const node_type &nodeId );
		bool eraseNode( const node_iterator &node );
		const node_set getOutNodesSet( const node_type& nodeId ) const;
		const node_set getInNodesSet( const node_type& nodeId ) const;
		int insertEdge( const node_type &fromNode, const node_type &toNode, const bool createNewNodes = true );
		int eraseEdge( const node_type &fromNode, const node_type &toNode, const bool removeIsolatedNodes = false );
		ostream& print( ostream& out ) const;
};

std::ostream& operator<<( std::ostream& out, const DirectionalGraph& graph );
}

#endif
