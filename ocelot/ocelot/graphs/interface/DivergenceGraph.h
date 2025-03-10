#ifndef DIVERGENCEGRAPH_H_
#define DIVERGENCEGRAPH_H_
/*
 * DivergenceGraph.h
 *
 *  Created on: May 20, 2010
 *      Author: Diogo Sampaio
 */

#include <ocelot/graphs/interface/DirectionalGraph.h>
#include <ocelot/ir/interface/PTXOperand.h>

namespace graph_utils {

class DivergenceGraph: public DirectionalGraph
{
	private:
		/*!\brief A set of nodes that are divergent because of a predecessor divergent block */
		node_set _divergentNodes;
		/*!\brief A set of nodes that are known to be special registers, possible sources of divergence */
		map<ir::PTXOperand::SpecialRegister, node_set> _specials;
		/*!\brief A set of nodes known to be divergent, probably because of creation divergent paths, atomic operands */
		node_set _divergenceSources;
		/*!\brief Defines if the divergence graph has been altered since the last computeDivergence() call */
		bool _upToDate;

	public:
		void clear();

		DivergenceGraph() : DirectionalGraph(), _upToDate(true){};
		~DivergenceGraph() {clear();};
		void insertSpecialSource( const ir::PTXOperand::SpecialRegister &tid );
		void eraseSpecialSource( const ir::PTXOperand::SpecialRegister &tid );
		void setAsDiv( const node_type &node );
		void unsetAsDiv( const node_type &node );
		bool eraseNode( const node_type &nodeId );
		bool eraseNode( const node_iterator &node );
		int insertEdge( const node_type &fromNode, const node_type &toNode, const bool createNewNodes = true );
		int insertEdge( const ir::PTXOperand::SpecialRegister &origin, const node_type &toNode, const bool createNewNodes = true );
		int eraseEdge( const node_type &fromNode, const node_type &toNode, const bool removeIsolatedNodes = false );
		int eraseEdge( const ir::PTXOperand::SpecialRegister &origin, const node_type &toNode, const bool removeIsolatedNodes = false );
		const node_set getDivNodes() const;
		bool isDivNode( const node_type &node ) const;
		bool isDivSource( const node_type &node ) const;
		bool isDivSource( const ir::PTXOperand::SpecialRegister srt ) const;
		bool hasSpecial( const ir::PTXOperand::SpecialRegister &special ) const;
		size_t divNodesCount() const;
		inline node_iterator beginDivNodes() const;
		inline node_iterator endDivNodes() const;
		void computeDivergence();
		const string getSpecialName( const ir::PTXOperand::SpecialRegister& in ) const;
		std::ostream& print( std::ostream& out ) const;
};

std::ostream& operator<<( std::ostream& out, const DivergenceGraph& graph );

}
#endif /* DIVERGENCEGRAPH_HPP_ */
