/*! \file PTXKernel.h
	\author Gregory Diamos <gregory.diamos@gatech>
	\date Thursday September 17, 2009
	\brief The header file for the PTXKernel class
*/

#ifndef IR_PTX_KERNEL_H_INCLUDED
#define IR_PTX_KERNEL_H_INCLUDED

#include <ocelot/ir/interface/Kernel.h>
#include <ocelot/analysis/interface/DataflowGraph.h>

namespace ir 
{
	/*!	A specialization of the kernel class for PTX */
	class PTXKernel : public Kernel 
	{
		public:
			/*!	\brief Vector of statements */
			typedef std::vector<PTXStatement> PTXStatementVector;

			/*! \brief A map from strings to registers */
			typedef std::unordered_map<std::string, 
				PTXOperand::RegisterType> RegisterMap;

			/*! \brief A map from register names to register types */
			typedef std::map< analysis::DataflowGraph::RegisterId, ir::PTXOperand::DataType > RegisterTypeMap;

			/*! \brief A set of registers */
			typedef analysis::DataflowGraph::RegisterVector RegisterVector;
			
		private:

			/*! \brief Add an operand op to regMap if it's a register
			    and it doesn't appear as a kernel parameter */
			void addUsedRegister(RegisterTypeMap& regMap, ir::PTXOperand& op) const;

		public:
			/*!	Constructs a control flow graph from iterators into the 
				Module's PTXStatement vector

				\param reference to newly constructed CFG
				\param kernelStart iterator to start of kernel 
					[i.e. the entry statement]
				\param kenelEnd iterator to end of kernel 
					[i.e. the EndEntry statement]
				\return true on successful creation
			*/
			static void constructCFG(
				ControlFlowGraph &cfg,
				PTXStatementVector::const_iterator kernelStart,
				PTXStatementVector::const_iterator kernelEnd );

			/*! \brief Assigns register IDs to identifiers */
			static RegisterMap assignRegisters(ControlFlowGraph& cfg);

		public:
			/*! \brief Constructs a blank new PTX kernel.
			
				\param name The name of the kernel
				\param isFunction Is this a kernel or a function?
			*/
			PTXKernel(const std::string& name = "", bool isFunction = false,
				const ir::Module* module = 0);
			
			/*! Constructs a kernel from an iterator into the PTXStatementVector

				\param start iterator into start of kernel
				\param end iterator into end of kernel
			*/
			PTXKernel(PTXStatementVector::const_iterator start,
				PTXStatementVector::const_iterator end, bool isFunction);

			/*! \brief Copy constructor (deep) */
			PTXKernel(const PTXKernel& k);
		
			/*! \brief Assignment operator (deep) */
			const PTXKernel& operator=(const PTXKernel& k);
	
		public:
			/*! \brief Get the set of all referenced 
				registers in the instruction set */
			RegisterVector getReferencedRegisters() const;

			/*! \brief Get the set of all referenced registers
			    in the instruction set without using DFG */
			RegisterTypeMap getReferencedRegistersWithoutDFG() const;

		public:
			/*! \brief Builds the data flow graph within the kernel */
			virtual analysis::DataflowGraph* dfg();

			/*! \brief Gets the datalow graph */
			virtual const analysis::DataflowGraph* dfg() const;

			/*! \brief renames all the blocks with canonical names */
			virtual void canonicalBlockLabels(int kernelID=1);

			/*!	Returns true if the kernel instance is derived from 
				ExecutableKernel */
			virtual bool executable() const;

			/*! \brief Write this kernel to a parseable string */
			virtual void write(std::ostream& stream) const;
			
	};

}

#endif

